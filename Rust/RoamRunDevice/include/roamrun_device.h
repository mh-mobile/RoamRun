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
 * Verifies the pairing (`pairing_len` bytes of a property list, never a path) with the device at `ip`:`port` (its RemotePairing
 * port) and opens the tunnel. Never starts a new pairing; sends the device no input.
 * Both ways: the device checks the pairing, and what answers must sign as the device the pairing
 * was made with. NULL on failure, with *error (if given) set to a message to free with
 * rr_string_free. Three kinds are known by how the message begins (nothing the other side wrote
 * is in those words): "this pairing doesn't hold the device's key" — one made before that key
 * was kept, or unreadable: like a refusal, only pairing again helps; "the device doesn't accept
 * this pairing" — the device proved itself and refused it (removed there); "not the device this
 * pairing was made with" — what answered didn't prove itself (it was told nothing of this
 * side's). Any other failure is of the connection.
 */
RRDevice *rr_device_open(const char *ip, uint16_t port, const uint8_t *pairing, size_t pairing_len, char **error);

/** Ends the tunnel. NULL is fine. Not while another call on it runs: the device is freed. */
void rr_device_close(RRDevice *device);

/**
 * `flag` — one byte, zero, that stays where it is while the device is open — is looked at when
 * a call begins, between the keys of a long input and at each step of a walk of the elements:
 * once raised (rr_flag_raise, from any thread), what is left isn't done and the call fails with
 * a message that begins "stopped:". For letting go of a device without waiting out a text.
 */
void rr_device_stop_at(RRDevice *device, const uint8_t *flag);
void rr_flag_raise(uint8_t *flag);
/** Lowered again, where the stop was for the call under way and the device is kept. */
void rr_flag_lower(uint8_t *flag);

/**
 * JSON: how long opening took and which of the services device control needs are there.
 * Free with rr_string_free.
 */
char *rr_device_info(RRDevice *device);

/**
 * JSON: {"ok":true,"width":…,"height":…}, the primary display's size in pixels as the device
 * holds it (portrait for a phone), by the device's own word. A frame of the stream can be a
 * little larger: padded on the right and at the bottom. Free with rr_string_free.
 */
char *rr_device_screen(RRDevice *device);

/**
 * One key frame of the device's screen, as Annex-B HEVC with its parameter sets first. The
 * screen stream is started for it and kept for a few seconds after (a later call asks the
 * running one for a key frame); the device shows a screen-sharing session meanwhile. No input.
 * NULL on failure, with *error (if given) set. Free the frame with rr_bytes_free.
 */
uint8_t *rr_device_keyframe(RRDevice *device, size_t *length, char **error);

/*
 * The calls below OPERATE THE DEVICE: look at a fresh frame first. Each returns JSON
 * ({"ok":true,"ms":…} or {"ok":false,"error":…}) to free with rr_string_free. A failure with
 * "invalid":true was refused for what was asked (a point off the screen, a key no keyboard
 * has) and nothing was sent; one whose error begins "stopped:" was told to stop (rr_flag_raise)
 * and sent what it had by then, the connection none the worse; any other may have reached the
 * device, and says nothing good about the connection. Points are
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
 * a key is sent.
 * The text appears as given only while the device's keyboard is an English one. With a
 * Japanese one the keys go to its conversion: Space converts, Return confirms instead of
 * breaking the line, and characters go missing. Look at a frame first; the globe key
 * switches keyboards (the Japanese keyboard's own "ABC" key does not). For text that must
 * arrive whatever the keyboard, there is rr_device_paste.
 */
char *rr_device_type(RRDevice *device, const char *text);

/**
 * Any text, into whatever has the keyboard's focus: puts it on the device's pasteboard and
 * presses Command-V. It REPLACES what was on the device's pasteboard. iOS then ASKS, each
 * time, whether the app may paste from another source: nothing is pasted until "Allow
 * Paste" is pressed on the device (look at a frame, and tap it if that is wanted).
 */
char *rr_device_paste(RRDevice *device, const char *text);

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

/**
 * A pairing a device comes to make (iOS 27 and later): this side listens and shows a code;
 * on the device, Settings lists it by `name` and asks for the code.
 */
typedef struct RRPairing RRPairing;

/**
 * Starts listening. *advert (free with rr_string_free) is JSON {"port":…,"identifier":…,
 * "txt":{…}}: publish a _remotepairing-pairable-host._tcp service named `identifier` on that
 * port with those TXT records, on the network the device is on. `model` is this Mac's model
 * identifier ("Mac16,1"). `host` is what tells this Mac from another, whatever either is
 * named: the same one each time, or a pairing made again adds to the device's list instead of
 * replacing. NULL on failure, with *error (if given) set.
 */
RRPairing *rr_pairing_listen(const char *name, const char *model, const char *host,
                             char **advert, char **error);

/**
 * Waits for a device to pair, however long one takes to come; once the code is shown it has
 * three minutes to be entered. After rr_pairing_cancel this returns at once. `code` is called
 * with the six digits to show the user (on another thread, before this returns). On success the pairing is
 * in the answer, never on disk: the JSON is {"ok":true,"udid":…,"name":…,"model":…,
 * "pairing":…} (a property list's text, holding this side's private key); otherwise
 * {"ok":false,"error":…}. Free with rr_string_free.
 */
char *rr_pairing_accept(RRPairing *pairing,
                        void (*code)(const char *code, void *context), void *context);

/** Makes a running rr_pairing_accept return. Any thread. */
void rr_pairing_cancel(RRPairing *pairing);

/** Stops listening. Not while rr_pairing_accept runs. NULL is fine. */
void rr_pairing_free(RRPairing *pairing);

/** Frees what a call returned as bytes; `length` is the length that call gave. */
void rr_bytes_free(uint8_t *bytes, size_t length);

void rr_string_free(char *string);

#endif
