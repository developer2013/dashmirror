// TouchBridge – C-Schnittstelle der Rust-Bibliothek (TouchBridge/src/lib.rs).
// Experiment: leitet Beruehrungen vom Autodisplay ueber LocalDevVPN an das eigene iPhone weiter.
#pragma once

#include <stddef.h>
#include <stdint.h>

#define TB_IDLE 0
#define TB_CONNECTING 1
#define TB_READY 2
#define TB_FAILED 3

/// Startet die Verbindung im Hintergrund. 0 = gestartet, -1 = ungueltige Argumente, -2 = laeuft schon.
int32_t touchbridge_start(const char *pairing_path, const char *host, uint16_t port);

/// contact 1 = Finger liegt an (x, y), 0 = Finger hebt ab. x, y: 0..65535 ueber den iPhone-Bildschirm
/// im Hochformat, (0, 0) = oben links. 0 = eingereiht, -1 = nicht bereit.
int32_t touchbridge_touch(uint8_t contact, uint16_t x, uint16_t y);

/// Beendet die Verbindung (asynchron).
void touchbridge_stop(void);

/// TB_IDLE, TB_CONNECTING, TB_READY oder TB_FAILED.
int32_t touchbridge_state(void);

uint64_t touchbridge_touches_sent(void);

/// Bytes des (verworfenen) Bildstroms, der als Freigabe fuer Beruehrungen laufen muss.
uint64_t touchbridge_stream_bytes(void);

/// Letzter Status/Fehler als UTF-8 nach buffer (nullterminiert). Rueckgabe: volle Laenge ohne Nullbyte.
size_t touchbridge_copy_status(char *buffer, size_t capacity);
