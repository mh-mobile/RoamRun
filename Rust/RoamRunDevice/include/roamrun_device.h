#ifndef ROAMRUN_DEVICE_H
#define ROAMRUN_DEVICE_H

#include <stddef.h>
#include <stdint.h>

/** Static, never freed. */
const char *rr_device_version(void);

/**
 * A device with a tunnel of our own to it. Use one from one thread at a time; a call made
 * while another runs waits for it. When the tunnel is gone (the device left, slept), calls
 * fail: close it and open another.
 */
typedef struct RRDevice RRDevice;

/**
 * Verifies the pairing in `pairing_file` with the device at `ip`:`port` (its RemotePairing
 * port) and opens the tunnel. Never starts a new pairing; sends the device no input.
 * NULL on failure, with *error (if given) set to a message to free with rr_string_free.
 */
RRDevice *rr_device_open(const char *ip, uint16_t port, const char *pairing_file, char **error);

/** Ends the tunnel. NULL is fine. */
void rr_device_close(RRDevice *device);

/**
 * JSON: how long opening took and which of the services device control needs are there.
 * Free with rr_string_free.
 */
char *rr_device_info(RRDevice *device);

/**
 * One key frame of the device's screen, as Annex-B HEVC with its parameter sets first: starts
 * the screen stream, takes the first complete key frame and stops it. Receives only.
 * NULL on failure, with *error (if given) set. Free the frame with rr_bytes_free.
 */
uint8_t *rr_device_keyframe(RRDevice *device, size_t *length, char **error);

/*
 * The calls below OPERATE THE DEVICE: look at a fresh frame first. Each returns JSON
 * ({"ok":true,"ms":…} or {"ok":false,"error":…}) to free with rr_string_free. Points are
 * fractions 0...1 of the screen as the device holds it (not rotated to the interface); one
 * outside 0...1 is refused, not moved to the edge. A screen stream runs for the length of
 * each: the device drops input that comes without one.
 */

/** One tap at (x, y): whatever is there gets pressed. */
char *rr_device_tap(RRDevice *device, double x, double y);

/** A finger down at (x1, y1), moved to (x2, y2) over duration_ms (50...5000), and lifted. */
char *rr_device_swipe(RRDevice *device, double x1, double y1, double x2, double y2,
                      uint32_t duration_ms);

/**
 * Types `text` as a hardware keyboard would, into whatever has the keyboard's focus. Only
 * what a US keyboard has (ASCII, and newline for Return); anything else is refused before
 * a key is sent. What appears depends on the device's hardware-keyboard layout.
 */
char *rr_device_type(RRDevice *device, const char *text);

/** Presses a hardware button: "home", "lock", "volume-up" or "volume-down". */
char *rr_device_button(RRDevice *device, const char *name);

/**
 * What accessibility says is on the screen: JSON {"ok":true,"elements":[{"caption":…}],
 * "complete":…,"ms":…}, captions as VoiceOver would speak them ("Home, tab, selected"),
 * in its order, from the first element until they repeat or `limit` is reached.
 * It sends no touch, but IT CAN MOVE THE SCREEN: the device scrolls to each element as
 * it is visited. Not a full tree: elements can be missing, the home screen gives none, and
 * a system alert in front gives only its own. No positions: a caption can't be tapped by
 * name. Free with rr_string_free.
 */
char *rr_device_elements(RRDevice *device, uint32_t limit);

void rr_bytes_free(uint8_t *bytes, size_t length);

void rr_string_free(char *string);

#endif
