# chanmgr – periodic Wi-Fi channel manager for OpenWrt

OpenWrt's `channel 'auto'` (hostapd ACS) picks a channel only when a radio comes
up. It never re-evaluates, and it does not know about your other access points.
chanmgr fills that gap:

* **Measures** the utilization of the current channel all day with passive survey
  samples (`iw survey dump`), excluding the radio's own transmit time.
* **Scans** neighbors at scheduled quiet hours (default 02:30 and 04:30), one
  node at a time, so the clients always have an access point that stays on channel.
* **Plans jointly**: it computes a cost per channel for every radio, adding a penalty when
  two of *your* access points overlap, weighted by how loudly they hear each other.
  Then it searches all channel combinations, or uses coordinate descent when there are too many.
* **Applies carefully**: it switches one radio at a time with CSA (`hostapd switch_chan`),
  checks the result, stops on the first failure and persists the new channel
  with `uci commit` only, without `wifi reload`.
* **Hysteresis**: it switches only when the gain is at least 25 % and 0.5 in cost,
  the same plan was proposed in 2 consecutive evaluations, and the radio did not
  switch in the last 24 h.
* **Safe defaults**: recommend-only mode, DFS off, 2.4 GHz restricted to 1/6/11.
  Allowed channels are read from the regulatory domain (`iw phy`), never from a
  fixed table. 6 GHz radios are ignored.

The same package runs on every device. Every node is an *agent* (rpcd methods
`chanmgr.agent_*`), and any node can be the *controller* that plans for all of
them: a router with its own radios, or a wired box without radios that manages
several access points.

## Repository layout

| Path | What |
| --- | --- |
| `files/` | the `chanmgr` package payload (ucode) |
| `files/usr/share/ucode/chanmgr/chan.uc` | channel math: blocks, spectrum overlap, candidates |
| `files/usr/share/ucode/chanmgr/parse.uc` | `iw` output parsers |
| `files/usr/share/ucode/chanmgr/score.uc` | cost model, joint plan search, hysteresis (pure) |
| `files/usr/share/ucode/chanmgr/agent.uc` | local measurements and CSA |
| `files/usr/share/ucode/chanmgr/remote.uc` | ubus-over-HTTP client for remote agents |
| `files/usr/share/ucode/chanmgr/controller.uc` | orchestration, state, scheduler |
| `luci-app-chanmgr/` | LuCI app, laid out as `applications/luci-app-chanmgr` in `openwrt/luci` |
| `chanmgr/Makefile` | package built from this repository (feed use) |
| `openwrt/net/chanmgr/Makefile.upstream` | package Makefile for the `openwrt/packages` feed |
| `tests/` | unit and end-to-end tests (host ucode, stubs for ubus/uci/agent) |
| `scripts/deploy.sh` | copy everything to a device for testing |

## Cost model

For a radio on a candidate channel:

```
cost = Σ neighbors overlap(candidate, neighbor) × 10^((rssi − ref_rssi)/10)
     + util_weight × utilization(candidate)
```

`overlap` is the shared spectrum as a fraction of the narrower of the two
channels. In 2.4 GHz a 20 MHz signal counts as 22 MHz wide, so 1/6/11 do not
overlap but 1/3 do. A neighbor received at `ref_rssi` (−70 dBm) costs 1.0, and
every +10 dB multiplies the cost by 10. `utilization` is the busy fraction
(busy − own tx) / active from the survey data.

For each pair of own access points in different units, the plan adds
`own_weight × overlap × weight(rssi they hear each other at)`. The plan
minimizes the total over all radios of a band.

### Channel width

With `width_analysis` on (off by default), the 5 GHz plan chooses channel and
width together. Interference alone always favours narrow channels, so options
are compared by estimated **capacity** instead, in units of one free 20 MHz
channel. A transmission uses a width only when every 20 MHz subchannel of that
block (built around the primary) is free, otherwise it falls back to a
narrower one:

```
capacity = P(20 free) + P(40 free) + 2 * P(80 free) + 4 * P(160 free)
```

The busy fraction of each 20 MHz channel is the mean of one survey sample per
evaluation over the last `history_days` (3), blended with a prior from the
neighbors heard on it, so the neighbor signal decides while there is little
data and the measurements take over as they accumulate. The channel in use is
measured all day, without the receive airtime of the AP's own clients
(per-station `rx duration`). Own access points that hear each other share
airtime where their channels overlap. The plan maximizes the total capacity
over all radios and widths in `widths_5g` (40, 80) plus the current one.

A width change is only proposed when every channel of the new option has
`history_days` of data, the capacity grows by at least 30 % and three
evaluations in a row propose it. It is applied by writing channel and
`htmode` (e.g. HE40 -> HE80), with the guarded restart on mesh radios.

Radios that must share a channel (802.11s mesh, batman-adv fallback links) go
into a **group**, and the group is planned and switched as a single unit. A radio
with a mesh interface that is not in a group is **locked**: the plan measures it
and the other radios avoid it, but it is never moved.

## Install for testing

On every device (controller and access points):

```sh
scripts/deploy.sh root@192.168.1.1 --luci   # --luci only where you want the UI
```

The device needs `ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci rpcd-mod-ucode
iw uclient-fetch`. The script warns about missing ones.

### Remote access points

On each access point, open **Network → Channel Manager → Configuration**, set
*Mode* to **Access point** and choose a user name and password. This creates an
rpcd login that can only use the agent methods (the `chanmgr-agent` ACL). The
password is hashed into `/etc/config/rpcd` and never stored in
`/etc/config/chanmgr`. Without LuCI:

```sh
uci set chanmgr.main.role='ap'; uci commit chanmgr
chanmgr agent login chanmgr 'a-long-secret'
```

The access point also needs `uhttpd` with `uhttpd-mod-ubus`, which comes with LuCI.
The controller talks to the same address as the access point's LuCI (`http://<host>/ubus`,
port 80). Leave `port` empty unless uhttpd listens elsewhere, and set `https` (plus
`insecure` for the default self-signed certificate) if the access point only serves HTTPS.
`root` and its password also work for a quick test, but the password is then
stored in plain text on the controller with full access to the access point.

On the controller (`/etc/config/chanmgr`, or **Network → Channel Manager →
Configuration**):

```
config node 'local'
	option enabled '0'          # this box has no radios

config node 'ap1'
	option host '192.168.1.2'
	option username 'chanmgr'
	option password 'a-long-secret'

config node 'ap2'
	option host '192.168.1.3'
	option username 'chanmgr'
	option password 'a-long-secret'

# batman-adv/802.11s fallback on the 5 GHz radios: keep them together
config group 'mesh5g'
	list member 'ap1/radio1'
	list member 'ap2/radio1'
```

Then:

```sh
chanmgr discover                       # every node answers with its radios?
CHANMGR_VERBOSE=1 chanmgr evaluate --dry-run --no-gap
chanmgr status
```

### Validate CSA before enabling apply mode

Switch each access point manually once (adjust interface and channel):

```sh
ubus call hostapd.phy1-ap0 switch_chan '{"freq":5745,"center_freq1":5775,"bandwidth":80,"sec_channel_offset":1,"bcn_count":10,"ht":true,"vht":true,"he":true}'
iw dev phy1-ap0 info
```

If that works on every access point, set `option mode 'apply'` and
`option enabled '1'`.

## CLI

```
chanmgr status | discover | sample | evaluate [--apply|--dry-run] [--no-gap] | apply | daemon
chanmgr agent info | survey | scan <radio>
```

## Options (`config chanmgr 'main'`)

| Option | Default | Meaning |
| --- | --- | --- |
| `role` | `router` | `router` plans for all nodes; `ap` only answers a router |
| `enabled` | `0` | run the scheduler service (router only) |
| `mode` | `recommend` | `recommend` (log and show) or `apply` |
| `eval_times` | `02:30 04:30` | local times of the scheduled evaluations; a slot missed by up to an hour still runs |
| `sample_interval` | `300` | seconds between utilization samples |
| `scan_gap` | `120` | seconds between the scans of two nodes |
| `apply_gap` | `30` | seconds between switching two units |
| `min_gain_rel` / `min_gain_abs` | `25` / `0.5` | minimum gain to switch |
| `confirm` | `2` | consecutive evaluations proposing the same plan |
| `min_switch_interval` | `86400` | seconds before a radio may move again |
| `allow_dfs` | `0` | consider channels 52–144 |
| `channels_2g` | `1 6 11` | 2.4 GHz candidates |
| `width_analysis` | `0` | 5 GHz: choose channel and width together by capacity |
| `widths_5g` | `40 80` | 5 GHz widths the plan may use |
| `history_days` | `3` | days of data a width change needs |
| `util_weight`, `own_weight`, `ref_rssi` | `2`, `2`, `-70` | cost model |
| `bcn_count` | `10` | CSA beacon count |
| `reload_fallback` | `0` | `wifi reload` if CSA fails (disconnects clients) |
| `mesh_method` | `reload` | radios with a mesh interface: `reload` (restart on the new channel) or `csa` (experimental) |

Each `config node` takes `host`, `port`, `https`, `insecure`, `username`,
`password`, `timeout`, `list lock`, `list exclude`. Without `host`, the node is
the local device. Each `config group` takes `list member 'node/radio'`.

## Known limitations

* The utilization of the current channel still includes what the radio's own
  clients receive (rx), which slightly favors switching. This is why
  evaluations run at night.
* While an agent scans (a few seconds), the rpcd of that access point is busy and LuCI
  requests to it wait.
* 2.4 GHz radios are planned and switched as 20 MHz channels.
* The channel width stays at the configured `htmode`. A fallback to a narrower width
  when 80 MHz blocks are all busy is planned.
* A channel switch announcement on a radio that hosts both AP and mesh
  interfaces can leave the radio down (seen on mt76). Such radios therefore get
  a *guarded restart* (`mesh_method 'reload'`), which disconnects their clients
  for a few seconds. Each node switches on its own and returns to the previous
  channel by itself when its radio does not come up, when its mesh peers do not
  return (`guard_mesh_timeout`), when the controller does not confirm
  (`guard_confirm_timeout`; the controller confirms only once every member of
  the group answers on the new channel), or when its mesh disappears within
  5 minutes after the switch. A marker in `/etc` restores the old channel at
  boot if power is lost mid-switch. This works without any wired link, since
  the decision never depends on reaching the controller.

## Tests

```sh
# build a host ucode once (needs cmake + libjson-c-dev)
git clone https://github.com/jow-/ucode && cmake -S ucode -B ucode/build \
  -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DULOOP_SUPPORT=OFF -DRTNL_SUPPORT=OFF \
  -DNL80211_SUPPORT=OFF -DDEBUG_SUPPORT=OFF -DLOG_SUPPORT=OFF -DDIGEST_SUPPORT=OFF
cmake --build ucode/build

UCODE=ucode/build/ucode UCODE_LIB=ucode/build ./tests/run.sh
```

## Build into your firmware

This repository is an OpenWrt feed (`chanmgr/` and `luci-app-chanmgr/`). In
your build tree:

```sh
echo 'src-git chanmgr https://github.com/lucascbd/luci-app-chanmgr.git' >> feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install chanmgr luci-app-chanmgr
make menuconfig
```

Select *LuCI → 3. Applications → luci-app-chanmgr* (it pulls `chanmgr`,
found under *Network → WirelessAPD*). The Brazilian Portuguese translation
`luci-i18n-chanmgr-pt-br` is selected with *LuCI → 2. Modules → Translations
→ Portuguese (Brazil)*. Append `;<branch>` or `^<commit>` to the feed line to
pin a version. Both packages are architecture independent, so the same build
serves every device (router and access points).

To try changes without rebuilding the firmware, `scripts/deploy.sh` copies the
files to a running device.

## Upstream submission

1. Tag a release (`v0.2.0`). In `openwrt/net/chanmgr/Makefile.upstream`, set
   `PKG_HASH` (`sha256sum` of the codeload tarball) and your full name in
   `PKG_MAINTAINER`.
2. PR to `openwrt/packages`: copy it to `net/chanmgr/Makefile`.
   Commit `chanmgr: add new package`, `Signed-off-by:` with your real name, and
   list compile- and run-tested targets in the PR.
3. After it is merged, PR to `openwrt/luci`: copy `luci-app-chanmgr/` to
   `applications/luci-app-chanmgr/` (its Makefile then uses `../../luci.mk`).
   Commit `luci-app-chanmgr: add new application`.

## License

GPL-2.0-only
