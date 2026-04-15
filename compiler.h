#ifndef COMPILER_H
#define COMPILER_H

#ifdef _MSC_VER
   #include <math.h>
   #include <malloc.h>

   #ifndef alloca
      #define alloca _alloca
   #endif

   #ifndef __builtin_constant_p
      #define __builtin_constant_p(x) 0
   #endif
   #ifndef __builtin_cos
      #define __builtin_cos(x) cos(x)
   #endif
   #ifndef __builtin_fabs
      #define __builtin_fabs(x) fabs(x)
   #endif
   #ifndef __builtin_floor
      #define __builtin_floor(x) floor(x)
   #endif
   #ifndef __builtin_copysign
      #define __builtin_copysign(x, y) _copysign((x), (y))
   #endif
#endif

#ifndef M_PI
   #define M_PI 3.14159265358979323846
#endif
#ifndef M_PI_2
   #define M_PI_2 1.57079632679489661923
#endif
#ifndef M_PI_4
   #define M_PI_4 0.78539816339744830962
#endif

// Manual branch optimization for GCC 3.0.0 and newer
#if !defined(__GNUC__) || __GNUC__ < 3
   #define likely(x) (x)
   #define unlikely(x) (x)
#else
   #define likely(x) __builtin_expect((long int)!!(x), true)
   #define unlikely(x) __builtin_expect((long int)!!(x), false)
#endif

// memccpy is available on POSIX (Linux glibc, mingw)
#if defined(__linux__) || defined(_WIN32)
   #define HAVE_MEMCCPY 1
#endif

#endif // COMPILER_H
