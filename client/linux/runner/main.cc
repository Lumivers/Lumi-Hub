#include <cstdlib>
#include <cstring>
#include "my_application.h"

int main(int argc, char** argv) {
  // If running in a Wayland session, prevent parent processes (like IDEs)
  // from forcing GDK_BACKEND=x11, which causes GTK3 to drop fractional scaling to 1.0x.
  const char* wayland_display = getenv("WAYLAND_DISPLAY");
  if (wayland_display != nullptr && wayland_display[0] != '\0') {
    const char* gdk_backend = getenv("GDK_BACKEND");
    if (gdk_backend != nullptr && strcmp(gdk_backend, "x11") == 0) {
      unsetenv("GDK_BACKEND");
    }
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
