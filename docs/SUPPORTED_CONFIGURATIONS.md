# Supported menu bar configurations

Barline's secondary Barline Bar and graphical drag layout editor require the
macOS menu bar to be configured as always visible. They are not certified for
automatically hidden system menu bars, including full-screen configurations
that hide the menu bar. Do not treat a passing build as evidence of that support.

When the macOS auto-hide preference is enabled, ordinary Barline section clicks
use native menu bar reveal instead of opening the secondary Barline Bar. The
saved Barline Bar preference and all saved layouts remain unchanged. Move the
pointer to the top edge to expose the system bar, then use its items normally.
The layout pane provides **Show Hidden Items in Menu Bar** and **Open Menu Bar
System Settings**. macOS Command-drag remains available for native arrangement.
Barline never changes the system auto-hide preference on the user's behalf.

The same explicit native reveal action is available as a recovery route from
the layout pane. After configuring the system menu bar to stay visible,
the secondary shelf and graphical layout editor become available again.

Runtime qualification must distinguish always-visible desktop, native fallback
under auto-hide, and full-screen Spaces. A runtime result for one does not
certify the others. macOS 27 and release-duration soak remain separate deferred
lanes. macOS 27 discovery has a separate read-only compatibility backend;
arrangement there uses native Command-drag rather than helper-owned mutation.
