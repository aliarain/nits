# DDC/CI field notes

Everything here was measured on real hardware while building Nits. It explains why
`DDCEngine`, `IOAVServiceProvider` and `DDCPacket` look the way they do.

Test machine: Apple M3 Pro, macOS 27.2, built-in Liquid Retina XDR plus a Dell/HKC
S4941XO 5120×1440 @ 240 Hz over a DCP DisplayPort path.

## Two transports

- **Apple Silicon** — `IOAVService` I2C against `DCPAVServiceProxy` registry nodes.
  Resolved with `dlsym` because the symbols are exported by IOKit but absent from the
  public SDK headers.
- **Intel** — `IOFramebuffer` I2C via `IOFBCopyI2CInterfaceForBus`, trying buses 0–7.

## Finding the right channel

The channel (`DCPAVServiceProxy`) and display identity (`DisplayAttributes`) live in
sibling subtrees, so parent-walk pairing fails. Nits uses two strategies:

1. **Location match (preferred).** CoreDisplay's `IODisplayLocation` names the display's
   framebuffer. Walk the registry tracking the current `IOMobileFramebuffer` registry ID;
   the first `DCPAVServiceProxy` under the matching framebuffer with `Location = External`
   is the channel. This is exact even for identical monitors.
2. **Proximity fallback.** If location is unavailable, walk the registry once and pair
   channels to displays by location, then vendor/product/serial, then traversal order.

The fallback is headless-tested in `DDCPairing`.

## MCDP29xx needs chip address 0xB7

Some Macs route HDMI through an `AppleDCPMCDP29XX` controller. DDC there is at chip
address **0xB7**, not the usual 0x37. Writing at 0x37 returns success but never reaches
the panel; reads return NULL frames. Nits checks the parent's `EPICProviderClass` and
switches to 0xB7 with a 50 ms reply delay.

On the test machine the display was on a normal DCP path (0x37); the 0xB7 branch is
for HDMI-connected panels.

## The double-send rule

With a single Get/Set VCP packet, this panel returned:

```
6E 80 BE 00 10 00 00 64 00 58 98 3A
```

`6E 80` is a DDC NULL frame, yet bytes 6–9 held a real current/max and byte 10 held the
checksum of the *real* reply. Sending the same request **twice, 10 ms apart**, produced:

```
6E 88 02 00 10 00 00 64 00 58 98 3A
```

The second packet is the one the panel serves. The same is true for Set VCP: the first
write ACKs without applying; the second applies. `m1ddc` ships the same double send and
was used as ground truth. Nits sends both Get and Set twice.

Relevant code: `IOAVChannel.sendRequest`, `IOAVChannel.write`.

## Validate replies, not ACKs

An I2C ACK does not mean a valid reply. Firmware can return:

- a DDC NULL frame;
- stale EDID bytes;
- an echo of the request;
- garbage with a plausible header.

A valid Get VCP reply is:

```
[0x6E, len, 0x02, result, vcpEcho, type, maxHi, maxLo, curHi, curLo, checksum]
```

Nits requires the source, opcode, zero result, VCP echo, and the checksum
(`0x50` seed over bytes 0–9). A zero max is also rejected, except for input select
where monitors legitimately report max 0.

## Timing

- 10 ms before each request write.
- 40 ms before reading a reply (50 ms for MCDP29xx).
- Reads are retried up to 3 times; writes up to 3 times.
- A single I2C operation over 500 ms is logged.
- A failed read that took ≥ 3 s is a deaf channel and quarantines reads immediately.

## Quarantine

After 6 failed reads a display's reads are quarantined for 10 minutes. A fresh probe
window opens when the quarantine expires. Writes are not quarantined. The quarantine
exists because hammering fragile controllers makes them worse; one AOC-class monitor
degrades from clean to garbage after a few reads.

## Caching and pumping

- VCP reads cached for 5 seconds.
- Writes invalidate that VCP's cache entry.
- UI writes are coalesced latest-wins with a 50 ms floor.
- Below 15%, hardware is held at 15% and gamma supplies the rest (perceived = hw × gamma).

## Disconnect hold

WindowServer's display enable waits behind an in-flight I2C transaction on the DCP.
With a wedged channel this can freeze the whole Mac, not just one app. Every
`SLSConfigureDisplayEnabled` transaction is therefore wrapped in a DDC hold:

1. drain every per-display queue;
2. park queues (existing and new) until the transaction returns;
3. release, with a 15 s safety cap so a lost release cannot wedge DDC forever.

## Mode IDs are volatile

`CGDisplayMode.ioDisplayModeID` changes whenever the mode list is rebuilt (reconnect,
HiDPI override inject/remove, sleep/wake). Presets and wake restore match by
width/height/refresh (±1 Hz)/HiDPI attributes, never by the ID.

## Other measured quirks

- **Volume max high byte.** A Dell reported `0xFF64` for a 0–100 range; use the low byte.
- **Input select.** The current value is the low byte; some monitors set flags in the
  high byte.
- **Input current 0x08.** The test panel reports an input code it does not list in its
  capabilities (`11 12 0F 10`). Nits displays the raw value rather than inventing a name.
- **Capabilities strings.** Chunked, often noisy, sometimes 400 bad chunks in a row.
  Nits caps both total bad chunks (64) and consecutive bad chunks (12) so a stubborn
  monitor cannot park the display's queue for tens of seconds.
- **Retina built-ins.** Brightness goes through DisplayServices, not DDC.
- **HDR.** Some HDR monitors ACK DDC brightness writes and discard them. Nits offers a
  per-display HDR software-dimming route through gamma.

## Recovery checklist

If a monitor stops responding:

1. open the monitor's OSD briefly;
2. replug the video cable (reconfiguration flushes every cache);
3. power-cycle the monitor (standby is not enough);
4. run `nitsctl doctor` and read the raw replies.
