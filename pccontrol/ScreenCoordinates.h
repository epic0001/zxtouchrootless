#ifndef ZX_SCREEN_COORDINATES_H
#define ZX_SCREEN_COORDINATES_H

#include <math.h>

// Rotation applied to the portrait image to produce the public screen frame.
typedef enum {
    ZXFrameUpright = 1,
    ZXFrameUpsideDown = 2,
    ZXFrameRotatedLeft = 3,
    ZXFrameRotatedRight = 4,
} ZXFrameRotation;

typedef struct {
    int width;
    int height;
    ZXFrameRotation rotation;
} ZXScreenFrame;

typedef struct {
    double x;
    double y;
} ZXNormalizedPoint;

static inline ZXScreenFrame ZXScreenFrameForPortrait(int width, int height, ZXFrameRotation rotation)
{
    if (rotation == ZXFrameRotatedLeft || rotation == ZXFrameRotatedRight) {
        return (ZXScreenFrame){height, width, rotation};
    }
    return (ZXScreenFrame){width, height, rotation};
}

// IOHID uses normalized portrait axes, even when the frame has been rotated.
static inline ZXNormalizedPoint ZXNormalizeTouch(ZXScreenFrame frame, double x, double y)
{
    double u = fmin(fmax(x / frame.width, 0.0), 1.0);
    double v = fmin(fmax(y / frame.height, 0.0), 1.0);
    switch (frame.rotation) {
        case ZXFrameUpsideDown: return (ZXNormalizedPoint){1.0 - u, 1.0 - v};
        case ZXFrameRotatedLeft: return (ZXNormalizedPoint){1.0 - v, u};
        case ZXFrameRotatedRight: return (ZXNormalizedPoint){v, 1.0 - u};
        case ZXFrameUpright: return (ZXNormalizedPoint){u, v};
    }
    return (ZXNormalizedPoint){u, v};
}

#endif
