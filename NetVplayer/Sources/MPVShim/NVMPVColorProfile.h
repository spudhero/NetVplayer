#ifndef NV_MPV_COLOR_PROFILE_H
#define NV_MPV_COLOR_PROFILE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>

// A retained, in-memory rendering profile; never installs a system profile.
// Matrix/single-gamma RGB profiles use the native ColorSync output response.
// Other bounded profile shapes pass through unchanged. NULL means failure.
CFDataRef nv_mpv_copy_render_profile(const void *bytes, size_t length);

#endif
