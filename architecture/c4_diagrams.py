"""Generate mcl-mpong's two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: what the service talks to
  c4-components.svg  Level 2: what it is made of

Drawn from the code, never from a template: the callbacks and subscriptions/0 in
apps/mcl_mpong/src/mcl_mpong_service.erl, the launch tree in mcl_mpong_sup.erl and
find_match.erl, the six topics in mcl_mpong_facts.erl, the coordinator's role machine
and the engine's tick rate, the deps in rebar.config, the realm and org settings in
config/sys.config.src, and the health port in the Containerfile. When one of those
changes, the diagram changes in the same commit.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS custom
properties (rsvg-convert renders those black), so the SVGs render the same on
GitHub, in IDE previews and through rsvg-convert. After a change, render each
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it; keep
architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        # A box that is too small for its own words renders as text on top of the
        # next box, which no test would catch and a reader would read as the
        # diagram saying something it does not. Fail here instead.
        need = 70 + 16 * max(len(desc) - 1, 0) + 18
        if h < need:
            raise ValueError(f"{self.name}: {name} needs height {need}, has {h}")
        for line in desc:
            if 16 + 6.2 * len(line) > w - 16:
                raise ValueError(f"{self.name}: {name}: '{line}' is wider than {w - 32}px")
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-mpong system context", 1000, 690)
    d.box("b-ext", 40, 30, 270, 120, "Spectator", "[External system]",
          ["macula-portal's mpong_subscriber:", "draws the path a match took; it", "reads v2 advert and state facts"])
    d.box("b-per", 365, 30, 270, 120, "Operator", "[Person]",
          ["Runs the two bots, one per", "box, and supplies the realm", "and the pinned stations"],
          person=True)
    d.box("b-ext", 690, 30, 270, 120, "Other bot", "[External system]",
          ["A second mcl-mpong on another", "box: host or challenger, the", "other end of the match"])
    d.box("b-sys", 365, 186, 270, 152, "mcl-mpong", "[mcl_om mesh service]",
          ["Publishes and subscribes to the six", "match facts on io.macula/mcl-mpong/", "mpong/match/*_v2, and answers /health",
           "on 8472. No own procedures, no store:", "a match lives in one process"])
    d.box("b-mac", 365, 430, 270, 120, "macula-realm", "[Macula infrastructure]",
          ["The trust anchor and the grant:", "the org mcl-mpong, scope for 30", "days, and the boot claim"])
    d.box("b-mac", 690, 430, 270, 120, "Macula stations, mesh DHT", "[Macula infrastructure]",
          ["The pinned dial; every fact goes", "through a station, and the DHT", "holds each advertisement"])
    d.edge("M400 186V168H175V150")
    d.text("t-rel", 200, 160, "the six facts, for any"); d.text("t-rel", 200, 176, "subscriber to read")
    d.edge("M500 150V186"); d.text("t-rel", 508, 164, "deploys the two bots")
    d.edge("M825 150V168H620V186"); d.text("t-rel", 632, 160, "the six match facts, both ways")
    d.edge("M460 338V430"); d.text("t-rel", 468, 384, "trust anchor, grant")
    d.edge("M620 338V370H825V430"); d.text("t-rel", 632, 364, "publishes and subscribes")
    d.text("t-desc", 40, 596, "No event store, by decision: a match is throwaway state in the engine process, and capabilities/0 is empty, so the")
    d.text("t-desc", 40, 614, "bot answers no procedure of its own. Its whole output is the facts it publishes, and a match needs two bots on different boxes:")
    d.text("t-desc", 40, 632, "one hosts the authoritative game and frames at 5 Hz, the other steers the far paddle and reports what it saw.")
    d.legend(650, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-mpong components", 1040, 1270)
    d.bound(40, 40, 968, 970, "mcl-mpong [Container]")
    d.box("b-cmp", 56, 70, 456, 120, "mcl_mpong_app", "[OTP application]",
          ["start/2 calls mcl_om:boot(mcl_mpong_service).", "No store_id/0 or data_dir/0 on the service, so",
           "mcl_om starts no reckon-db and no subscription."], code=True)
    d.box("b-sys", 536, 70, 456, 120, "mcl_mpong_service", "[:mcl_om_service behaviour]",
          ["The six callbacks plus subscriptions/0, which", "gives mcl_om one subscriber per match fact.",
           "capabilities/0 is empty; scope mcl-mpong, 30 days."], code=True)
    d.box("b-cmp", 56, 230, 456, 120, "mcl_mpong_sup", "[supervisor, rest_for_one]",
          ["Starts host_match_sup, then find_match. If the", "engine supervisor goes, the coordinator is",
           "restarted with it, since its monitor went too."], code=True)
    d.box("b-cmp", 536, 230, 456, 120, "mcl_mpong_facts", "[Erlang module]",
          ["The six topics and their payloads, at version 2,", "and parse/2 for what a subscriber receives.",
           "A test pins every topic and every key."], code=True)
    d.box("b-cmp", 56, 390, 456, 120, "host_match_sup", "[supervisor, simple_one_for_one]",
          ["start_engine/1 puts one engine under it, and", "the engine is temporary: a match that crashes",
           "is over, not restarted."], code=True)
    d.box("b-sys", 536, 390, 456, 120, "find_match", "[gen_server, the coordinator]",
          ["Owns the role and the current match: seeking,", "hosting, challenging, playing. Publishes the",
           "advert and seat facts; each child emits its own."], code=True)
    d.box("b-cmp", 56, 550, 456, 120, "mpong_game_engine", "[gen_server, 25 Hz]",
          ["The host's authoritative game: a frame every", "fifth tick, 5 Hz, emitted through the closure",
           "find_match gave it. Ball, ai, collision calls."], code=True)
    d.box("b-cmp", 536, 550, 456, 120, "play_remote_paddle", "[gen_server, 25 Hz]",
          ["The challenger's paddle: steers at the last", "ball it saw and emits a numbered move every",
           "second tick, with its own view of the mesh."], code=True)
    d.box("b-cmp", 56, 710, 456, 120, "mesh_gauge", "[Erlang module, pure]",
          ["Sequence gaps, round trip (minus the time the", "host held the move, so no clock sync is",
           "assumed), and the stations a pool is on."], code=True)
    d.box("b-cmp", 536, 710, 456, 120, "hear_match_facts", "[macula_subscriber, one per topic]",
          ["Declared by subscriptions/0. Parses nothing", "and decides nothing: the payload and the",
           "verified meta go straight to find_match."], code=True)
    d.box("b-mac", 56, 870, 456, 120, "mcl_om", "[library, ~> 1.4]",
          ["boot/1: loads the identity key, joins the", "realm, dials the pinned stations, starts one",
           "subscriber per topic, serves /health on 8472."], code=True)
    d.box("b-mac", 536, 870, 456, 120, "macula SDK", "[library, ~> 16.0, wire 1.0]",
          ["QUIC transport, pubsub over the stations, and", "the publisher every link verified, which is",
           "what a fact's attribution rests on."], code=True)
    d.edge("M56 130H16V930H56"); d.text("t-rel", 30, 530, "calls mcl_om:boot/1", anchor="middle", rotate=-90)
    d.edge("M512 130H536"); d.text("t-rel", 524, 122, "boots", anchor="middle")
    d.edge("M536 160H520V210H284V230"); d.text("t-rel", 300, 206, "starts")
    d.edge("M200 350V390"); d.text("t-rel", 208, 374, "starts")
    d.edge("M350 350V370H520V430H536"); d.text("t-rel", 420, 366, "starts second")
    d.edge("M536 490H520V530H284V510"); d.text("t-rel", 340, 526, "start_engine/1")
    d.edge("M200 510V550"); d.text("t-rel", 208, 546, "one engine, temporary")
    d.edge("M864 510V550"); d.text("t-rel", 856, 534, "starts on seat_reserved", anchor="end")
    d.edge("M600 390V350"); d.text("t-rel", 608, 380, "advert and seat facts")
    d.edge("M512 620H530V360H760V350"); d.text("t-rel", 768, 380, "builds each frame")
    d.edge("M992 610H1012V360H900V350"); d.text("t-rel", 908, 380, "builds each move")
    d.edge("M200 670V710"); d.text("t-rel", 208, 694, "moves seen, missed")
    d.edge("M536 610H520V690H350V710"); d.text("t-rel", 400, 686, "frames and round trip")
    d.edge("M992 770H1024V530H880V510"); d.text("t-rel", 890, 522, "facts as they arrive")
    d.edge("M512 930H536"); d.text("t-rel", 524, 922, "dials", anchor="middle")
    d.box("b-ext", 64, 1040, 920, 104, "Host environment", "[read at boot; nothing here is baked into the image]",
          ["MCL_REALM and MCL_REALM_NAME are both required and must agree: the service refuses to start unless the sha256 of the name is the tag.",
           "MCL_REALM_KEY is the trust anchor; MACULA_STATION_SEEDS with MACULA_STATION_NODE_IDS is the pinned dial; MCL_HEALTH_PORT is 8472."],
          code=True)
    d.text("t-desc", 64, 1180, "No event store, by decision: a match is throwaway state in the engine process, and capabilities/0 is empty, so the bot answers no")
    d.text("t-desc", 64, 1198, "procedure (Raf, 2026-09-23). find_match publishes the advert and seat facts itself, and hands each child an emit closure that")
    d.text("t-desc", 64, 1216, "builds and publishes there, a frame each and a move each. Health is the match's: degraded when unpaired 15 minutes or the peer silent 3 s.")
    d.legend(1240)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()
