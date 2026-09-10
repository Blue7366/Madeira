// FEX supplies its own memory resources, but derives them from libc++'s
// std::pmr::memory_resource. Its out-of-line destructor and RTTI were only
// added to Apple's runtime in iOS 17 / macOS 14.
//
// Supply the stateless base destructor when deploying below those versions.
// Defining the key function also emits the matching vtable and type information.
// This is NOT the full PMR runtime: CI rejects any remaining PMR imports.
// The macOS branch lets the same implementation be exercised by the host test.
#if defined(__APPLE__) && \
    ((defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__) && \
      __ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__ < 170000) || \
     (defined(__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__) && \
      __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 140000))

// Only this implementation file disables availability annotations: it provides
// the missing definition locally instead of calling an unavailable dylib API.
#define _LIBCPP_DISABLE_AVAILABILITY
#include <memory_resource>

#ifndef _LIBCPP_VERSION
#error "PMRCompat requires Apple's libc++ ABI"
#endif

_LIBCPP_BEGIN_NAMESPACE_STD
namespace pmr {
memory_resource::~memory_resource() = default;
} // namespace pmr
_LIBCPP_END_NAMESPACE_STD

#endif
