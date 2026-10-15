// Enclosure for the KVM: Raspberry Pi 4 + Waveshare HDMI-to-CSI adapter (TC358743).
//
// Layout (top view):
//
//            back wall:  [ adapter HDMI in ]
//          +---------------------------------+
//          |        +---------+              |
//          |        | adapter |  (cradle)    |
//          |        +----+----+              |
//          |             | CSI ribbon        |
//   micro  |  +----------|--------------+    | USB / Ethernet
//   SD  -> |  |  Pi 4    |              |    | (right wall)
//          |  +--------------------------+   |
//          +---------------------------------+
//            front wall: USB-C (splitter), optional micro-HDMI / audio
//
// The adapter sits on the floor behind the Pi's GPIO edge, with its HDMI port
// against the back wall and its ribbon connector facing the Pi. The ribbon runs
// straight from there to the Pi's CAMERA connector without a twist.
//
// Print `part = "base"` and `part = "lid"` separately (lid prints top-down as
// exported). `part = "assembly"` is a preview only.
//
// Hardware: 4x M2.5 x 12 pan-head screws. Each goes up through the floor, a
// standoff and a Pi mounting hole into a post on the lid, so the same four
// screws clamp the Pi and hold the lid on. Optional: 4x M2.5 screws for the
// adapter if adapter_mount = "screws".
//
// The board outline (about 42 x 26 mm) was measured by hand; the hole
// positions, HDMI position and ribbon-connector side are best guesses. The "cradle" mount doesn't depend on the hole
// positions, which is why it is the default.

/* [What to render] */
part = "assembly"; // [assembly, base, lid]

/* [Case] */
wall        = 2.2;   // side wall thickness
floor_t     = 2.0;   // floor thickness
lid_t       = 2.0;   // lid thickness
inner_h     = 26;    // floor top to lid underside; must clear the USB stack (~22.5)
corner_r    = 3;     // outside corner radius
pi_standoff = 5;     // Pi PCB bottom above the floor
fit         = 0.4;   // general clearance around boards

/* [Raspberry Pi 4] */
pi_w        = 85;
pi_d        = 56;
pi_pcb      = 1.5;
pi_holes    = [[3.5, 3.5], [61.5, 3.5], [3.5, 52.5], [61.5, 52.5]];
pi_port_overhang = 3.0; // USB/Ethernet stick out past the board edge by this much
sd_overhang = 2.5;      // microSD card sticks out past the left edge

/* [Front wall openings (Pi USB-C edge)] */
usbc_cut_w  = 13;    // generous so the USB-C splitter plug fits
usbc_cut_h  = 8;
cut_micro_hdmi = false; // the KVM doesn't use the Pi's own HDMI outputs
cut_audio      = false;

/* [Waveshare HDMI-to-CSI adapter] */
ad_w        = 26.2;  // size across the case (x), measured ~25-26 mm
ad_d        = 42.2;  // size front-to-back (y), HDMI on the back edge, measured ~41-42 mm
ad_pcb      = 1.6;
ad_gap      = 6;     // space between the Pi's GPIO edge and the adapter (ribbon bend)
ad_center_x = 45;    // in Pi coordinates; 45 lines the ribbon up with the CAMERA connector
ad_standoff = 3;     // adapter PCB bottom above the floor
ad_hdmi_w   = 15.5;  // HDMI receptacle width
ad_hdmi_h   = 6.5;   // HDMI receptacle height above the adapter PCB top
ad_hdmi_off = 0;     // HDMI centre offset from the adapter's centre line (x)
ad_hdmi_overhang = 0.5; // how far the HDMI shell sticks past the board edge
adapter_mount = "cradle"; // [cradle, screws]
ad_holes_inset = 3;  // "screws" only: hole centres this far in from each corner
ad_hole_d   = 2.2;   // "screws" only: pilot for M2.5 self-tapping

/* [Cooling] */
fan         = false; // 30 mm fan in the lid over the SoC
fan_size    = 30;
fan_hole_pitch = 24;
lid_vents   = true;  // slots in the lid over the SoC (ignored when fan = true)
side_vents  = true;  // slots in the left wall

/* [Hidden] */
$fn = 40;
eps = 0.01;

// Pi 4 SoC centre and CAMERA connector, in Pi coordinates
soc  = [29, 32];
csi  = [45, 11.5];

// Interior extents, origin = Pi board corner (USB-C edge / microSD edge)
in_x0 = -(sd_overhang + fit);
in_x1 = pi_w + pi_port_overhang + fit;
in_y0 = -1.5;
ad_y0 = pi_d + ad_gap;
in_y1 = ad_y0 + ad_d + ad_hdmi_overhang + fit;

in_w = in_x1 - in_x0;
in_d = in_y1 - in_y0;
out_w = in_w + 2 * wall;
out_d = in_d + 2 * wall;

pi_z  = floor_t + pi_standoff;              // Pi PCB bottom
ad_z  = floor_t + ad_standoff;              // adapter PCB bottom
ad_x0 = ad_center_x - ad_w / 2;


module rounded_box(w, d, h, r) {
    hull() for (x = [r, w - r], y = [r, d - r])
        translate([x, y, 0]) cylinder(r = r, h = h);
}

// Everything below is placed in Pi coordinates; this moves case coordinates there.
module at_pi() {
    translate([wall - in_x0, wall - in_y0, 0]) children();
}



module port_cut_y(x, z, w, h) {  // opening through the front wall
    translate([x - w / 2, in_y0 - wall - 1, z]) cube([w, wall + 2, h]);
}
module port_cut_x(y, z, w, h) {  // opening through the right wall
    translate([in_x1 - 1, y - w / 2, z]) cube([wall + 2, w, h]);
}

module base() {
    pcb_top = pi_z + pi_pcb;
    ad_top  = ad_z + ad_pcb;
    difference() {
        union() {
            difference() {
                rounded_box(out_w, out_d, floor_t + inner_h, corner_r);
                at_pi() translate([in_x0, in_y0, floor_t])
                    cube([in_w, in_d, inner_h + 1]);
            }
            at_pi() {
                // Pi standoffs
                for (h = pi_holes) translate([h[0], h[1], 0])
                    cylinder(d = 7, h = pi_z);
                // adapter mount
                translate([ad_x0, ad_y0, 0]) adapter_mount();
            }
        }
        at_pi() {
            // M2.5 clearance through floor and standoff, head recessed underneath
            for (h = pi_holes) translate([h[0], h[1], 0]) {
                translate([0, 0, -1]) cylinder(d = 2.9, h = pi_z + 2);
                translate([0, 0, -1]) cylinder(d = 5.2, h = 2.2 + 1);
            }

            // Front wall: USB-C (power/data splitter)
            port_cut_y(11.2, pcb_top + 1.6 - usbc_cut_h / 2, usbc_cut_w, usbc_cut_h);
            if (cut_micro_hdmi) for (x = [26, 39.5])
                port_cut_y(x, pcb_top - 1, 10, 6);
            if (cut_audio)
                port_cut_y(53.5, pcb_top - 0.5, 8, 8);

            // Right wall: USB 3, USB 2, Ethernet
            for (y = [9, 27]) port_cut_x(y, pcb_top - 0.5, 15, 17);
            port_cut_x(45.75, pcb_top - 0.5, 17, 15);

            // Left wall: microSD slot (card sits under the PCB)
            translate([in_x0 - wall - 1, 28 - 8, pi_z - 3.5])
                cube([wall + 2, 16, 5]);

            // Back wall: adapter HDMI in
            translate([ad_center_x + ad_hdmi_off - (ad_hdmi_w + 1.5) / 2,
                       in_y1 - 1, ad_top - 0.75])
                cube([ad_hdmi_w + 1.5, wall + 2, ad_hdmi_h + 1.5]);

            // Left wall vents
            if (side_vents) for (i = [0 : 4])
                translate([in_x0 - wall - 1, 62 + i * 8, floor_t + 6])
                    cube([wall + 2, 3, inner_h - 12]);
        }
    }
}

module adapter_mount() {
    // local coords: adapter board corner at origin
    if (adapter_mount == "cradle") {
        // Low rails on three sides; the back wall closes the fourth. The board
        // rests on corner pads and the lid's hold-down posts keep it there.
        rail_h = ad_z + ad_pcb + 1.5;
        difference() {
            translate([-fit - 1.6, -fit - 1.6, 0])
                cube([ad_w + 2 * fit + 3.2, ad_d + 2 * fit + 1.6 + 2, rail_h]);
            translate([-fit, -fit, ad_z]) cube([ad_w + 2 * fit, ad_d + 10, 10]);
            // open under the board so parts on the underside clear the floor
            translate([4, 4, floor_t]) cube([ad_w - 8, ad_d + 10, 10]);
            // slot in the front rail for the ribbon to leave
            translate([2, -fit - 2, ad_z]) cube([ad_w - 4, 3, 10]);
        }
    } else {
        for (x = [ad_holes_inset, ad_w - ad_holes_inset],
             y = [ad_holes_inset, ad_d - ad_holes_inset])
            translate([x, y, 0]) difference() {
                cylinder(d = 5, h = ad_z);
                translate([0, 0, floor_t]) cylinder(d = ad_hole_d, h = ad_z);
            }
    }
}

module lid() {
    // Modelled in place (bottom face at the top of the walls).
    lip = 1.6;
    ad_top = ad_z + ad_pcb;
    top = floor_t + inner_h;
    difference() {
        union() {
            rounded_box(out_w, out_d, lid_t, corner_r);
            // inner lip keeps the lid from sliding
            at_pi() difference() {
                translate([in_x0 + fit, in_y0 + fit, -2])
                    cube([in_w - 2 * fit, in_d - 2 * fit, 2]);
                translate([in_x0 + fit + lip, in_y0 + fit + lip, -3])
                    cube([in_w - 2 * fit - 2 * lip, in_d - 2 * fit - 2 * lip, 4]);
            }
            // posts down onto the Pi's mounting holes; the screws from
            // underneath thread into these
            at_pi() for (h = pi_holes)
                translate([h[0], h[1], -(top - pi_z - pi_pcb)])
                    cylinder(d = 6, h = top - pi_z - pi_pcb + eps);
            // adapter hold-down posts (board corners)
            at_pi() for (x = [ad_x0 + 1.5, ad_x0 + ad_w - 1.5],
                         y = [ad_y0 + 1.5, ad_y0 + ad_d - 1.5])
                translate([x, y, -(top - ad_top) + 0.3])
                    cylinder(d = 2.5, h = top - ad_top - 0.3 + eps);
        }
        at_pi() {
            // M2.5 pilots in the Pi posts (stop short of the lid top)
            for (h = pi_holes)
                translate([h[0], h[1], -(top - pi_z - pi_pcb) - 1])
                    cylinder(d = 2.2, h = top - pi_z - pi_pcb + 1 - 0.8);
            if (fan) {
                translate([soc[0], soc[1], -1])
                    cylinder(d = fan_size - 2, h = lid_t + 2);
                for (sx = [-1, 1], sy = [-1, 1])
                    translate([soc[0] + sx * fan_hole_pitch / 2,
                               soc[1] + sy * fan_hole_pitch / 2, -1])
                        cylinder(d = 2.9, h = lid_t + 2);
            } else if (lid_vents) {
                for (i = [-3 : 3])
                    translate([soc[0] - 15, soc[1] + i * 5 - 1.25, -1])
                        cube([30, 2.5, lid_t + 2]);
            }
        }
    }
}

// --- Preview boards (assembly only) ---
module ghost_boards() {
    at_pi() {
        color("green", 0.6) translate([0, 0, pi_z]) cube([pi_w, pi_d, pi_pcb]);
        color("silver", 0.6) {
            for (y = [9, 27]) translate([pi_w - 17 + pi_port_overhang, y - 6.6, pi_z + pi_pcb])
                cube([17, 13.2, 16]);
            translate([pi_w - 21 + pi_port_overhang, 45.75 - 8, pi_z + pi_pcb]) cube([21, 16, 13.5]);
        }
        color("blue", 0.6) translate([ad_x0, ad_y0, ad_z]) cube([ad_w, ad_d, ad_pcb]);
        color("silver", 0.6)
            translate([ad_center_x + ad_hdmi_off - ad_hdmi_w / 2,
                       ad_y0 + ad_d + ad_hdmi_overhang - 11, ad_z + ad_pcb])
                cube([ad_hdmi_w, 11, ad_hdmi_h - 0.5]);
        // ribbon path
        color("orange", 0.8) hull() {
            translate([csi[0] - 8, csi[1], pi_z + pi_pcb + 5]) cube([16, 1, 0.2]);
            translate([ad_center_x - 8, ad_y0 - 1, ad_z + ad_pcb + 3]) cube([16, 1, 0.2]);
        }
    }
}

if (part == "base") {
    base();
} else if (part == "lid") {
    // flip so the flat top is on the print bed
    translate([0, out_d, lid_t]) rotate([180, 0, 0]) lid();
} else {
    base();
    ghost_boards();
    color("white", 0.35) translate([0, 0, floor_t + inner_h + 8]) lid();
}
