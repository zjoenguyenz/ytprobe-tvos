// YT Probe — the ONLY import of the contained WebKit bridge
// header. Same containment rule as JoeTV: no WebKit type or
// symbol appears anywhere in Swift; the bridge resolves the
// framework at runtime.
#import "JoeWebBridge.h"
