// panel_test.mm  (macOS only)
// Loads the built CLAP, opens its panel through the CLAP GUI extension in an
// offscreen window, renders screenshots, drives the controls with synthetic
// mouse events, checks that edits reach the host as gesture/value events,
// tests presets, and closes everything again.
//
//   panel_test <path to the .clap binary> <output dir for PNGs>

#import <Cocoa/Cocoa.h>

#include <clap/clap.h>

#include "Params.h"
#include "Editor.h"

#include <dlfcn.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>

static int failures = 0;
static void check (bool ok, const char* what)
{
    std::printf ("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (! ok) ++failures;
}

static int flushRequests = 0;
static void hpRescan (const clap_host_t*, clap_param_rescan_flags) {}
static void hpClear (const clap_host_t*, clap_id, clap_param_clear_flags) {}
static void hpRequestFlush (const clap_host_t*) { ++flushRequests; }
static const clap_host_params_t hostParams = { hpRescan, hpClear, hpRequestFlush };
static const void* hGetExt (const clap_host_t*, const char* id) { return ! std::strcmp (id, CLAP_EXT_PARAMS) ? &hostParams : nullptr; }
static void hNoop (const clap_host_t*) {}
static const clap_host_t host = { CLAP_VERSION_INIT, nullptr, "panel_test", "TB", "", "1.0", hGetExt, hNoop, hNoop, hNoop };

struct OutEvents
{
    int values = 0, begins = 0, ends = 0;
    clap_output_events_t list;
    OutEvents() { list.ctx = this; list.try_push = &sPush; }
    static bool sPush (const clap_output_events_t* l, const clap_event_header_t* h)
    {
        OutEvents* o = (OutEvents*) l->ctx;
        if (h->type == CLAP_EVENT_PARAM_VALUE) ++o->values;
        if (h->type == CLAP_EVENT_PARAM_GESTURE_BEGIN) ++o->begins;
        if (h->type == CLAP_EVENT_PARAM_GESTURE_END) ++o->ends;
        return true;
    }
};
static uint32_t noEvents (const clap_input_events_t*) { return 0; }
static const clap_event_header_t* noGet (const clap_input_events_t*, uint32_t) { return nullptr; }

static NSData* renderPNG (NSView* v, const std::string& path)
{
    const NSRect b = [v bounds];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect: b];
    [v cacheDisplayInRect: b toBitmapImageRep: rep];
    NSData* png = [rep representationUsingType: NSBitmapImageFileTypePNG properties: [NSDictionary dictionary]];
    [png writeToFile: [NSString stringWithUTF8String: path.c_str()] atomically: YES];
    std::printf ("  wrote %s (%lu bytes)\n", path.c_str(), (unsigned long) [png length]);
    return png;
}

// panelPt is in face coordinates; the face sits inside the mahogany frame
static void mouse (NSWindow* w, NSView* v, NSEventType type, NSPoint panelPt, int clicks = 1)
{
    const NSPoint wp = [v convertPoint: NSMakePoint ((panelPt.x + tbm50::kPanelFrame) * tbm50::kPanelScale,
                                                     (panelPt.y + tbm50::kPanelFrame) * tbm50::kPanelScale) toView: nil];
    NSEvent* e = [NSEvent mouseEventWithType: type location: wp modifierFlags: 0 timestamp: 0
                                windowNumber: [w windowNumber] context: nil eventNumber: 0
                                  clickCount: clicks pressure: 1.0f];
    if (type == NSEventTypeRightMouseDown) [v rightMouseDown: e];
    else if (type == NSEventTypeLeftMouseDown) [v mouseDown: e];
    else if (type == NSEventTypeLeftMouseDragged) [v mouseDragged: e];
    else [v mouseUp: e];
}
static void click (NSWindow* w, NSView* v, NSPoint pt, int clicks = 1)
{
    mouse (w, v, NSEventTypeLeftMouseDown, pt, clicks);
    mouse (w, v, NSEventTypeLeftMouseUp, pt, clicks);
}
static void pump (double secs) { [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: secs]]; }

static double val (const clap_plugin_t* p, const clap_plugin_params_t* pp, int id)
{
    double v = -1; pp->get_value (p, (clap_id) id, &v); return v;
}

// One processing block, so queued panel edits reach the "host".
static void processBlock (const clap_plugin_t* p, OutEvents& out)
{
    std::vector<float> l (256, 0.0f), r (256, 0.0f), ol (256), orr (256);
    float* ins[2] = { &l[0], &r[0] };
    float* outs[2] = { &ol[0], &orr[0] };
    clap_audio_buffer_t ib; std::memset (&ib, 0, sizeof (ib)); ib.data32 = ins; ib.channel_count = 2;
    clap_audio_buffer_t ob; std::memset (&ob, 0, sizeof (ob)); ob.data32 = outs; ob.channel_count = 2;
    clap_input_events_t in = { nullptr, noEvents, noGet };
    clap_process_t pr; std::memset (&pr, 0, sizeof (pr));
    pr.steady_time = -1; pr.frames_count = 256;
    pr.audio_inputs = &ib; pr.audio_inputs_count = 1; pr.audio_outputs = &ob; pr.audio_outputs_count = 1;
    pr.in_events = &in; pr.out_events = &out.list;
    p->process (p, &pr);
}

// Play a decaying 110 Hz pluck on the left and a steady tone on the right (VUs, OVERLOAD LED)
static void playSine (const clap_plugin_t* p, double amp, int blocks)
{
    static double phase = 0.0;
    std::vector<float> l (256), r (256), ol (256), orr (256);
    for (int b = 0; b < blocks; ++b)
    {
        for (int i = 0; i < 256; ++i)
        {
            const double t = phase / (2.0 * 3.14159265358979 * 110.0 / 44100.0) / 44100.0;
            l[i] = (float) (amp * std::sin (phase) * std::exp (-std::fmod (t, 0.25) * 9.0));
            r[i] = (float) (0.35 * amp * std::sin (2.0 * phase));
            phase += 2.0 * 3.14159265358979 * 110.0 / 44100.0;
        }
        float* ins[2] = { &l[0], &r[0] };
        float* outs[2] = { &ol[0], &orr[0] };
        clap_audio_buffer_t ib; std::memset (&ib, 0, sizeof (ib)); ib.data32 = ins; ib.channel_count = 2;
        clap_audio_buffer_t ob; std::memset (&ob, 0, sizeof (ob)); ob.data32 = outs; ob.channel_count = 2;
        clap_input_events_t in = { nullptr, noEvents, noGet };
        OutEvents out;
        clap_process_t pr; std::memset (&pr, 0, sizeof (pr));
        pr.steady_time = -1; pr.frames_count = 256;
        pr.audio_inputs = &ib; pr.audio_inputs_count = 1; pr.audio_outputs = &ob; pr.audio_outputs_count = 1;
        pr.in_events = &in; pr.out_events = &out.list;
        p->process (p, &pr);
    }
}

static void setParam (const clap_plugin_t* p, const clap_plugin_params_t* pp, int id, double v)
{
    clap_event_param_value_t ev; std::memset (&ev, 0, sizeof (ev));
    ev.header.size = sizeof (ev); ev.header.space_id = CLAP_CORE_EVENT_SPACE_ID; ev.header.type = CLAP_EVENT_PARAM_VALUE;
    ev.param_id = (clap_id) id; ev.value = v; ev.note_id = -1; ev.port_index = -1; ev.channel = -1; ev.key = -1;
    struct L { static uint32_t size (const clap_input_events_t*) { return 1; }
               static const clap_event_header_t* get (const clap_input_events_t* l, uint32_t) { return (const clap_event_header_t*) l->ctx; } };
    clap_input_events_t in = { &ev, L::size, L::get };
    OutEvents o; pp->flush (p, &in, &o.list);
}

static CGFloat faderPos (float v) { return 742.0 - v * 142.0; }

int main (int argc, char** argv)
{
    if (argc < 3) { std::printf ("usage: %s <clap binary> <png dir>\n", argv[0]); return 2; }
    setvbuf (stdout, 0, _IONBF, 0);
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];
    const std::string dir = argv[2];

    const std::string presetFile = dir + "/test_presets/Presets.txt";
    setenv ("TBM50_PRESET_FILE", presetFile.c_str(), 1);
    std::remove (presetFile.c_str());

    void* lib = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
    if (! lib) { std::printf ("dlopen failed: %s\n", dlerror()); return 1; }
    const clap_plugin_entry_t* entry = (const clap_plugin_entry_t*) dlsym (lib, "clap_entry");
    entry->init (argv[1]);
    const clap_plugin_factory_t* f = (const clap_plugin_factory_t*) entry->get_factory (CLAP_PLUGIN_FACTORY_ID);
    const clap_plugin_t* p = f->create_plugin (f, &host, f->get_plugin_descriptor (f, 0)->id);
    p->init (p);
    p->activate (p, 44100.0, 1, 4096);
    p->start_processing (p);
    const clap_plugin_params_t* pp = (const clap_plugin_params_t*) p->get_extension (p, CLAP_EXT_PARAMS);

    using namespace tbm50;
    std::printf ("Panel\n");
    const clap_plugin_gui_t* gui = (const clap_plugin_gui_t*) p->get_extension (p, CLAP_EXT_GUI);
    check (gui && gui->is_api_supported (p, CLAP_WINDOW_API_COCOA, false), "supports an embedded Cocoa panel");
    uint32_t w = 0, h = 0;
    check (gui->create (p, CLAP_WINDOW_API_COCOA, false) && gui->get_size (p, &w, &h) && w == (uint32_t) kEditorWidth && h == (uint32_t) kEditorHeight,
           "panel size as declared (616 x 774: the 770 x 968 panel at 80 %)");

    NSWindow* win = [[NSWindow alloc] initWithContentRect: NSMakeRect (0, 0, w, h) styleMask: NSWindowStyleMaskBorderless
                                                  backing: NSBackingStoreBuffered defer: NO];
    NSView* parent = [win contentView];
    clap_window_t cw; cw.api = CLAP_WINDOW_API_COCOA; cw.cocoa = parent;
    check (gui->set_parent (p, &cw) && gui->show (p), "panel attaches to the host's view");
    check ([[parent subviews] count] == 1, "panel view added");
    NSView* panel = [[parent subviews] count] ? [[parent subviews] objectAtIndex: 0] : nil;
    if (! panel) return 1;
    NSData* pngDefault = renderPNG (panel, dir + "/panel_default.png");
    check ([pngDefault length] > 10000, "panel renders");

    std::printf ("\nControls\n");
    {
        OutEvents out;
        const CGFloat capY = faderPos (0.75f);
        mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (108, capY));
        mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (108, capY + 35.5));
        mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (108, capY + 35.5));
        processBlock (p, out);
        const double g1 = val (p, pp, kCh1 + kCFader);
        std::printf ("  CH 1 fader 0.75 -> %.3f\n", g1);
        check (std::fabs (g1 - 0.5) < 0.02, "dragging a fader down follows the hand");
        check (out.values > 0 && out.begins == 1 && out.ends == 1, "host gets begin / value / end");
        click (win, panel, NSMakePoint (108, faderPos ((float) g1)), 2);
        check (std::fabs (val (p, pp, kCh1 + kCFader) - kDefaults[kCh1 + kCFader]) < 1e-6, "double-click resets a fader");
    }
    {
        std::vector<int> ps;
        std::vector<NSPoint> at;
        const CGFloat cx[2] = { 108, 268 };
        const CGFloat eqY[3] = { 334, 408, 482 };
        const int gains[3] = { kCHiGain, kCMidGain, kCLoGain }, freqs[3] = { kCHiFreq, kCMidFreq, kCLoFreq };
        for (int c = 0; c < 2; ++c)
        {
            ps.push_back (chParam (c, kCTrim)); at.push_back (NSMakePoint (cx[c], 212));
            for (int b = 0; b < 3; ++b)
            {
                ps.push_back (chParam (c, gains[b])); at.push_back (NSMakePoint (cx[c], eqY[b]));
                ps.push_back (chParam (c, freqs[b])); at.push_back (NSMakePoint (cx[c], eqY[b] - 18));
            }
            ps.push_back (chParam (c, kCPan));   at.push_back (NSMakePoint (cx[c], 556));
            ps.push_back (chParam (c, kCFader)); at.push_back (NSMakePoint (cx[c], faderPos (0.5f)));
        }
        ps.push_back (kMaster); at.push_back (NSMakePoint (602, faderPos (0.5f)));
        bool all = true;
        for (size_t k = 0; k < ps.size(); ++k)
        {
            for (size_t j = 0; j < ps.size(); ++j) setParam (p, pp, ps[j], 0.5);
            mouse (win, panel, NSEventTypeLeftMouseDown,    at[k]);
            mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (at[k].x, at[k].y - 20));
            mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (at[k].x, at[k].y - 20));
            bool others = true;
            for (size_t j = 0; j < ps.size(); ++j) if (j != k && val (p, pp, ps[j]) != 0.5) others = false;
            if (! (val (p, pp, ps[k]) > 0.55) || ! others) { all = false; std::printf ("  control %d did not move alone\n", ps[k]); }
        }
        for (size_t j = 0; j < ps.size(); ++j) setParam (p, pp, ps[j], kDefaults[ps[j]]);
        check (all, "all 19 knobs and faders move, each on its own");
    }
    {
        const CGFloat xs[3] = { 80, 108, 136 };
        int got[3];
        for (int k = 0; k < 3; ++k) { click (win, panel, NSMakePoint (xs[k], 152)); got[k] = (int) val (p, pp, kCh1 + kCInput); }
        std::printf ("  INPUT clicks: %d %d %d\n", got[0], got[1], got[2]);
        check (got[0] == 0 && got[1] == 1 && got[2] == 2, "INPUT: MIC, D.I., LINE where they are marked");
        click (win, panel, NSMakePoint (148, 278));
        check (val (p, pp, kCh1 + kCBypass) == 1.0, "EQ BYPASS latches in");
        setParam (p, pp, kCh1 + kCInput, 0.0);
        pump (0.1);
        renderPNG (panel, dir + "/panel_switches.png");
        click (win, panel, NSMakePoint (148, 278));
        check (val (p, pp, kCh1 + kCBypass) == 0.0, "and out again");
        setParam (p, pp, kCh1 + kCInput, 2.0);
        click (win, panel, NSMakePoint (602, 506));
        check (val (p, pp, kBypass) == 1.0, "BYPASS latches in");
        pump (0.1);
        renderPNG (panel, dir + "/panel_bypassed.png");
        click (win, panel, NSMakePoint (602, 506));
        check (val (p, pp, kBypass) == 0.0, "and out again");
    }
    {
        setParam (p, pp, kCh1 + kCMidFreq, 0.3);
        click (win, panel, NSMakePoint (602, 446));
        check (val (p, pp, kLink) == 1.0, "LINK latches in");
        check (std::fabs (val (p, pp, kCh2 + kCMidFreq) - 0.3) < 1e-6, "and copies channel 1 into channel 2");
        const double t2 = val (p, pp, kCh2 + kCTrim);
        mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (268, 212));
        mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (268, 182));
        mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (268, 182));
        check (val (p, pp, kCh2 + kCTrim) == t2, "channel 2's linked knobs don't turn");
        mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (108, 212));
        mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (108, 192));
        mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (108, 192));
        check (val (p, pp, kCh2 + kCTrim) == val (p, pp, kCh1 + kCTrim) && val (p, pp, kCh1 + kCTrim) > t2, "channel 1's TRIM turns both");
        const double p2 = val (p, pp, kCh2 + kCPan);
        mouse (win, panel, NSEventTypeLeftMouseDown,    NSMakePoint (268, 556));
        mouse (win, panel, NSEventTypeLeftMouseDragged, NSMakePoint (268, 576));
        mouse (win, panel, NSEventTypeLeftMouseUp,      NSMakePoint (268, 576));
        check (val (p, pp, kCh2 + kCPan) < p2, "channel 2's PAN still turns on its own");
        mouse (win, panel, NSEventTypeRightMouseDown, NSMakePoint (108, 408 - 18));
        pump (0.1);
        renderPNG (panel, dir + "/panel_linked.png");
        click (win, panel, NSMakePoint (602, 446));
        check (val (p, pp, kLink) == 0.0, "LINK out again");
        setParam (p, pp, kCh2 + kCHiFreq, 0.2);
        const double h1 = val (p, pp, kCh1 + kCHiFreq), h2 = val (p, pp, kCh2 + kCHiFreq);
        mouse (win, panel, NSEventTypeRightMouseDown, NSMakePoint (268, 334 - 18));
        pump (0.1);
        renderPNG (panel, dir + "/panel_compare.png");
        check (val (p, pp, kCh1 + kCHiFreq) == h1 && val (p, pp, kCh2 + kCHiFreq) == h2, "right-click changes nothing");
        for (int i = 0; i < kNumParams; ++i) setParam (p, pp, i, (i == kCh1 + kCInput || i == kCh2 + kCInput) ? (double) inputIndex (kDefaults[i]) : (double) kDefaults[i]);
    }

    std::printf ("\nPresets\n");
    #define SLOT(k) NSMakePoint (226.0 + (k) * 46.0 + 20.0, 837.0)
    auto fileHasName = [&]() {
        bool named = false;
        FILE* pf = std::fopen (presetFile.c_str(), "r");
        if (pf) { char ln[512]; while (std::fgets (ln, sizeof (ln), pf)) if (std::strstr (ln, "name 3: Drum buss glue")) named = true; std::fclose (pf); }
        return named;
    };
    setParam (p, pp, kCh1 + kCHiGain, 0.8);
    setParam (p, pp, kCh2 + kCBypass, 1.0);
    pump (0.1);
    click (win, panel, NSMakePoint (184, 837));      // SAVE
    click (win, panel, SLOT (2));                     // slot 3
    FILE* pf = std::fopen (presetFile.c_str(), "r");
    check (pf != 0, "SAVE then a slot writes the preset file");
    if (pf) std::fclose (pf);
    NSTextField* field = nil;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) field = (NSTextField*) sv;
    check (field != nil, "saving opens a box to name the preset");
    renderPNG (panel, dir + "/panel_naming.png");
    if (field)
    {
        [field setStringValue: @"Drum buss glue"];
        [field sendAction: [field action] to: [field target]];
        pump (0.2);
    }
    check (fileHasName(), "Return saves the name with the preset");
    bool gone = true;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) gone = false;
    check (gone, "and the name box goes away");
    setParam (p, pp, kCh1 + kCHiGain, 0.2);
    setParam (p, pp, kCh2 + kCBypass, 0.0);
    click (win, panel, SLOT (2));
    check (std::fabs (val (p, pp, kCh1 + kCHiGain) - 0.8) < 1e-5 && val (p, pp, kCh2 + kCBypass) == 1.0, "clicking the slot recalls the saved settings");
    renderPNG (panel, dir + "/panel_preset_loaded.png");
    click (win, panel, NSMakePoint (429, 885));
    field = nil;
    for (NSView* sv in [panel subviews]) if ([sv isKindOfClass: [NSTextField class]]) field = (NSTextField*) sv;
    check (field != nil && [[field stringValue] isEqualToString: @"Drum buss glue"], "clicking the readout opens the name to edit");
    if (field)
    {
        [field setStringValue: @"Something else"];
        [(id) panel control: field textView: nil doCommandBySelector: @selector (cancelOperation:)];   // Esc
        pump (0.2);
    }
    check (fileHasName(), "Esc keeps the old name");
    const double before = val (p, pp, kCh1 + kCHiGain);
    click (win, panel, SLOT (5));
    check (val (p, pp, kCh1 + kCHiGain) == before, "an empty slot changes nothing");
    for (int i = 0; i < kNumParams; ++i) setParam (p, pp, i, (i == kCh1 + kCInput || i == kCh2 + kCInput) ? (double) inputIndex (kDefaults[i]) : (double) kDefaults[i]);

    std::printf ("\nHost changes show on the panel\n");
    pump (0.1);
    NSData* pngBefore = renderPNG (panel, dir + "/panel_before_host.png");
    setParam (p, pp, kMaster, 0.4);
    setParam (p, pp, kCh2 + kCPan, 0.5);
    pump (0.3);
    NSData* pngAfter = renderPNG (panel, dir + "/panel_changed.png");
    check (! [pngAfter isEqualToData: pngBefore], "panel redraws after host changes");
    setParam (p, pp, kMaster, kDefaults[kMaster]);
    setParam (p, pp, kCh2 + kCPan, kDefaults[kCh2 + kCPan]);

    std::printf ("\nMeters follow the audio\n");
    {
        setParam (p, pp, kCh1 + kCTrim, 0.9); setParam (p, pp, kCh1 + kCLoGain, 0.7);
        setParam (p, pp, kCh1 + kCHiFreq, 0.4); setParam (p, pp, kCh1 + kCHiGain, 0.65);
        setParam (p, pp, kCh2 + kCMidFreq, 0.35); setParam (p, pp, kCh2 + kCMidGain, 0.3);
        setParam (p, pp, kCh1 + kCFader, 0.62);
        click (win, panel, NSMakePoint (108, 212));      // readout shows TRIM
        pump (0.2);
        NSData* quiet = renderPNG (panel, dir + "/panel_meters_off.png");
        playSine (p, 0.35, 51);                            // ends 45 ms after a hit: the LED mid-flash
        pump (0.3);
        NSData* lit = renderPNG (panel, dir + "/panel_showcase.png");
        check (! [lit isEqualToData: quiet], "VUs and the OVERLOAD LED follow the audio");
    }

    std::printf ("\nClose\n");
    gui->hide (p);
    gui->destroy (p);
    check ([[parent subviews] count] == 0, "destroying the GUI removes the panel");
    check (gui->create (p, CLAP_WINDOW_API_COCOA, false) && gui->set_parent (p, &cw) && [[parent subviews] count] == 1, "reopens");
    gui->destroy (p);
    p->stop_processing (p);
    p->deactivate (p);
    p->destroy (p);
    entry->deinit();
    [win release];
    [pool release];
    dlclose (lib);

    std::printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "ALL PANEL CHECKS PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
