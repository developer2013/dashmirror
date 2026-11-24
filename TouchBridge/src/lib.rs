// TouchBridge – Beruehrungen vom Autodisplay an das eigene iPhone weitergeben.
//
// Ablauf (nachgebaut aus jkcoxson/idevice, MIT: ffi/src/tunnel_provider.rs `finish_tunnel` und
// tools/src/coredevice_stream.rs `start_screen_media_stream`, tools/src/hid.rs `with_touch`):
//
//   1. TCP zu 10.7.0.1:49152 – LocalDevVPN leitet das an das iPhone selbst zurueck.
//   2. Remote Pairing mit der Kopplungsdatei (pair-verify, kein PIN) -> TLS-PSK-Tunnel.
//   3. Ueber den Tunnel (eigener TCP/UDP-Stapel, jktcp) das Diensteverzeichnis (RSD).
//   4. displayservice: Bildstrom starten. Ohne laufenden Strom verwirft backboardd jede
//      Beruehrung ("unsupported service"). Die RTP-Pakete werden nur weggelesen.
//   5. hid.universalhidservice: 58-Byte-Touchscreen-Berichte, Koordinaten 0..65535.
//
// Alles laeuft auf EINEM eigenen Thread mit einer tokio-Laufzeit; die C-Funktionen unten
// kehren sofort zurueck und blockieren den Hauptthread von DashMirror nie.
// Gemessen vom Mac aus am 24.11.2026 (iPhone 16 Pro, iOS 27.0.1): 5/5 Tipps kamen an,
// auch waehrend der ReplayKit-Uebertragung.

use std::ffi::{CStr, c_char};
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::time::Duration;

use idevice::RsdService;
use idevice::core_device::{
    CallInfoBlob, DisplayServiceClient, TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE,
    UniversalHidServiceClient, build_screen_audio_offer, build_screen_video_offer,
    build_start_audio_parameters, build_start_video_parameters,
};
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::AdapterHandle;
use tokio::sync::mpsc;

// ------------------------------------------------------------------ Zustand

pub const TB_IDLE: i32 = 0;
pub const TB_CONNECTING: i32 = 1;
pub const TB_READY: i32 = 2;
pub const TB_FAILED: i32 = 3;

static STATE: AtomicI32 = AtomicI32::new(TB_IDLE);
static TOUCHES_SENT: AtomicU64 = AtomicU64::new(0);
static RTP_BYTES: AtomicU64 = AtomicU64::new(0);
static STATUS: Mutex<String> = Mutex::new(String::new());
static SENDER: Mutex<Option<mpsc::UnboundedSender<Command>>> = Mutex::new(None);

/// Wie Xcode/Device Hub: was WIR als Empfaenger koennen (nicht die Maske des Geraets).
const CLIENT_SUPPORTED_FEATURES: u64 = 140;
/// So lange darf jeder Netzwerkschritt dauern, bevor wir aufgeben.
const STEP_TIMEOUT: Duration = Duration::from_secs(10);

enum Command {
    Touch { contact: bool, x: u16, y: u16 },
    Stop,
}

fn set_status(text: impl Into<String>) {
    if let Ok(mut s) = STATUS.lock() {
        *s = text.into();
    }
}

async fn step<T, E: std::fmt::Debug>(
    what: &str,
    fut: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, String> {
    set_status(format!("{what} …"));
    match tokio::time::timeout(STEP_TIMEOUT, fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("{what}: {e:?}")),
        Err(_) => Err(format!("{what}: Zeitueberschreitung")),
    }
}

// ------------------------------------------------------------------ Verbindung

async fn open_tunnel(
    pairing_path: &str,
    addr: SocketAddr,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let mut pairing = step("Kopplungsdatei lesen", RpPairingFile::read_from_file(pairing_path)).await?;

    let stream = step("Verbinden mit LocalDevVPN", tokio::net::TcpStream::connect(addr)).await?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "DashMirror");
    // Nur pair-verify: Ein PIN wuerde bedeuten, dass die Kopplungsdatei nicht (mehr) passt.
    step("Kopplung pruefen", rpc.connect(&mut pairing, || async { String::new() })).await?;

    let tunnel_port = step("Tunnel anfordern", rpc.create_tcp_listener()).await?;
    let mut tunnel_addr = addr;
    tunnel_addr.set_port(tunnel_port);
    let tunnel_stream =
        step("Tunnel verbinden", tokio::net::TcpStream::connect(tunnel_addr)).await?;
    let tunnel = step(
        "Tunnel verschluesseln",
        connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key()),
    )
    .await?;

    let client_ip: IpAddr = tunnel.info.client_address.parse().map_err(|e| format!("{e}"))?;
    let server_ip: IpAddr = tunnel.info.server_address.parse().map_err(|e| format!("{e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.min(8192) - 60);
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = step("Diensteverzeichnis", adapter.connect(rsd_port)).await?;
    let handshake = step("Diensteverzeichnis lesen", RsdHandshake::new(rsd_stream)).await?;
    Ok((adapter, handshake))
}

async fn run(pairing_path: String, addr: SocketAddr, mut rx: mpsc::UnboundedReceiver<Command>) -> Result<(), String> {
    let (mut adapter, mut handshake) = open_tunnel(&pairing_path, addr).await?;

    // --- Bildstrom als Freigabe (Audio zuerst, dann Video auf derselben Sitzung – wie Device Hub)
    let mut display = step(
        "Bildschirmdienst",
        DisplayServiceClient::connect_rsd(&mut adapter, &mut handshake),
    )
    .await?;
    let audio_udp = step("UDP Ton", adapter.bind_udp(0)).await?;
    let video_udp = step("UDP Bild", adapter.bind_udp(0)).await?;
    let receiver_ip = adapter.host_ip().to_string();
    let sender_ip = adapter.peer_ip().to_string();
    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };
    let session_id = uuid::Uuid::new_v4();

    let audio_call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let audio_offer =
        build_screen_audio_offer(&audio_call_id, &call_info).map_err(|e| format!("Ton-Angebot: {e:?}"))?;
    let audio_params = build_start_audio_parameters(
        &receiver_ip,
        audio_udp.local_port(),
        &sender_ip,
        50000,
        audio_offer,
        CLIENT_SUPPORTED_FEATURES,
        session_id,
    );
    step("Tonstrom starten", display.start_media_stream(audio_params)).await?;

    let video_call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
    let video_offer = build_screen_video_offer(&video_call_id, &call_info, ssrc)
        .map_err(|e| format!("Bild-Angebot: {e:?}"))?;
    let video_params = build_start_video_parameters(
        &receiver_ip,
        video_udp.local_port(),
        &sender_ip,
        50001,
        video_offer,
        CLIENT_SUPPORTED_FEATURES,
        1,
        session_id,
    );
    step("Bildstrom starten", display.start_media_stream(video_params)).await?;

    // backboardd braucht einen Moment, bis die HID-Flaechen als "builtIn" gelten.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let mut hid = step(
        "Beruehrungsdienst",
        UniversalHidServiceClient::connect_rsd(&mut adapter, &mut handshake),
    )
    .await?;

    STATE.store(TB_READY, Ordering::SeqCst);
    set_status("bereit");

    // Hauptschleife: RTP wegwerfen (sonst puffert jktcp unbegrenzt), Befehle ausfuehren.
    let result = loop {
        tokio::select! {
            biased;
            cmd = rx.recv() => match cmd {
                Some(Command::Touch { contact, x, y }) => {
                    let state = if contact { TOUCHSCREEN_STATE_CONTACT } else { TOUCHSCREEN_STATE_RELEASE };
                    if let Err(e) = hid.send_touchscreen(state, x, y, None).await {
                        break Err(format!("Beruehrung senden: {e:?}"));
                    }
                    TOUCHES_SENT.fetch_add(1, Ordering::Relaxed);
                }
                Some(Command::Stop) | None => break Ok(()),
            },
            pkt = video_udp.recv() => match pkt {
                Ok(d) => { RTP_BYTES.fetch_add(d.data.len() as u64, Ordering::Relaxed); }
                Err(e) => break Err(format!("Bildstrom abgerissen: {e}")),
            },
            pkt = audio_udp.recv() => match pkt {
                Ok(d) => { RTP_BYTES.fetch_add(d.data.len() as u64, Ordering::Relaxed); }
                Err(e) => break Err(format!("Tonstrom abgerissen: {e}")),
            },
        }
    };

    // Ordentlich aufraeumen, damit am iPhone die Bildschirmfreigabe endet.
    let _ = tokio::time::timeout(Duration::from_secs(2), display.stop_media_stream()).await;
    result
}

// ------------------------------------------------------------------ C-Schnittstelle

/// Startet die Verbindung im Hintergrund. Rueckgabe 0 = gestartet, -1 = ungueltige Argumente,
/// -2 = laeuft schon. Den Fortschritt liefern `touchbridge_state` und `touchbridge_copy_status`.
///
/// # Safety
/// `pairing_path` und `host` muessen gueltige, nullterminierte UTF-8-Zeichenketten sein.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn touchbridge_start(pairing_path: *const c_char, host: *const c_char, port: u16) -> i32 {
    if pairing_path.is_null() || host.is_null() {
        return -1;
    }
    let (Ok(path), Ok(host)) = (
        unsafe { CStr::from_ptr(pairing_path) }.to_str(),
        unsafe { CStr::from_ptr(host) }.to_str(),
    ) else {
        return -1;
    };
    let Ok(ip) = host.parse::<IpAddr>() else { return -1 };
    let addr = SocketAddr::new(ip, port);
    let path = path.to_string();

    let mut sender = SENDER.lock().unwrap_or_else(|e| e.into_inner());
    if sender.is_some() {
        return -2;
    }
    let (tx, rx) = mpsc::unbounded_channel();
    *sender = Some(tx);
    drop(sender);

    STATE.store(TB_CONNECTING, Ordering::SeqCst);
    TOUCHES_SENT.store(0, Ordering::Relaxed);
    RTP_BYTES.store(0, Ordering::Relaxed);
    set_status("starte …");

    std::thread::Builder::new()
        .name("TouchBridge".into())
        .spawn(move || {
            let outcome = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(rt) => rt.block_on(run(path, addr, rx)),
                Err(e) => Err(format!("tokio: {e}")),
            };
            if let Ok(mut s) = SENDER.lock() {
                *s = None;
            }
            match outcome {
                Ok(()) => {
                    set_status("gestoppt");
                    STATE.store(TB_IDLE, Ordering::SeqCst);
                }
                Err(e) => {
                    set_status(e);
                    STATE.store(TB_FAILED, Ordering::SeqCst);
                }
            }
        })
        .map(|_| 0)
        .unwrap_or_else(|_| {
            STATE.store(TB_FAILED, Ordering::SeqCst);
            set_status("Thread liess sich nicht starten");
            -3
        })
}

/// Eine Beruehrung: `contact` 1 = Finger liegt (an dieser Stelle), 0 = Finger hebt ab.
/// `x`, `y` normiert auf 0..65535 ueber den iPhone-Bildschirm im Hochformat (0,0 = oben links).
/// Rueckgabe 0 = eingereiht, -1 = nicht bereit.
#[unsafe(no_mangle)]
pub extern "C" fn touchbridge_touch(contact: u8, x: u16, y: u16) -> i32 {
    if STATE.load(Ordering::SeqCst) != TB_READY {
        return -1;
    }
    match SENDER.lock().ok().and_then(|s| s.clone()) {
        Some(tx) if tx.send(Command::Touch { contact: contact != 0, x, y }).is_ok() => 0,
        _ => -1,
    }
}

/// Beendet die Verbindung (asynchron). Danach geht der Zustand auf TB_IDLE.
#[unsafe(no_mangle)]
pub extern "C" fn touchbridge_stop() {
    if let Some(tx) = SENDER.lock().ok().and_then(|s| s.clone()) {
        let _ = tx.send(Command::Stop);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn touchbridge_state() -> i32 {
    STATE.load(Ordering::SeqCst)
}

#[unsafe(no_mangle)]
pub extern "C" fn touchbridge_touches_sent() -> u64 {
    TOUCHES_SENT.load(Ordering::Relaxed)
}

/// Bytes, die der Bildstrom bisher geliefert hat (werden verworfen) – zeigt die Kosten der Freigabe.
#[unsafe(no_mangle)]
pub extern "C" fn touchbridge_stream_bytes() -> u64 {
    RTP_BYTES.load(Ordering::Relaxed)
}

/// Kopiert den letzten Status/Fehler (UTF-8, nullterminiert, ggf. gekuerzt) nach `buffer`.
/// Rueckgabe: volle Laenge in Bytes ohne Nullbyte.
///
/// # Safety
/// `buffer` muss auf mindestens `capacity` beschreibbare Bytes zeigen (oder null sein).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn touchbridge_copy_status(buffer: *mut c_char, capacity: usize) -> usize {
    let text = STATUS.lock().map(|s| s.clone()).unwrap_or_default();
    let bytes = text.as_bytes();
    if !buffer.is_null() && capacity > 0 {
        let mut n = bytes.len().min(capacity - 1);
        while n > 0 && !text.is_char_boundary(n) {
            n -= 1; // nicht mitten in einem Umlaut abschneiden
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, n);
            *buffer.add(n) = 0;
        }
    }
    bytes.len()
}
