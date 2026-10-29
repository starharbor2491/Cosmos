// Cosmos Helper: the executable of Chromium's GPU, network, renderer and other processes. Chromium starts it from the
// helper apps next to the framework (`Contents/Frameworks/Cosmos Helper*.app`).
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char *argv[]) {
  // Chromium's sandbox, first: a renderer, the GPU process and most others run in it (one that does not need it is let
  // go on as it is).
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader library;
  if (!library.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  return CefExecuteProcess(args, nullptr, nullptr);
}
