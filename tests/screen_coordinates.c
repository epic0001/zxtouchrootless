#include "../pccontrol/ScreenCoordinates.h"
#include <assert.h>

static void expect_point(ZXScreenFrame frame, double x, double y, double expected_x, double expected_y)
{
    ZXNormalizedPoint point = ZXNormalizeTouch(frame, x, y);
    assert(fabs(point.x - expected_x) < 1e-9);
    assert(fabs(point.y - expected_y) < 1e-9);
}

int main(void)
{
    // The same off-center physical point viewed in all four orientations.
    ZXScreenFrame portrait = ZXScreenFrameForPortrait(1242, 2208, ZXFrameUpright);
    ZXScreenFrame upside_down = ZXScreenFrameForPortrait(1242, 2208, ZXFrameUpsideDown);
    ZXScreenFrame left = ZXScreenFrameForPortrait(1242, 2208, ZXFrameRotatedLeft);
    ZXScreenFrame right = ZXScreenFrameForPortrait(1242, 2208, ZXFrameRotatedRight);
    assert(portrait.width == 1242 && portrait.height == 2208);
    assert(left.width == 2208 && left.height == 1242);
    assert(right.width == 2208 && right.height == 1242);
    expect_point(portrait, 310.5, 276, 0.25, 0.125);
    expect_point(upside_down, 931.5, 1932, 0.25, 0.125);
    expect_point(left, 276, 931.5, 0.25, 0.125);
    expect_point(right, 1932, 310.5, 0.25, 0.125);
    expect_point(left, 0, 0, 1.0, 0.0);
    expect_point(right, 0, 0, 0.0, 1.0);

    // On-disk iPhone 8 Plus recordings and live touches reach the same point.
    expect_point(ZXScreenFrameForPortrait(1080, 1920, ZXFrameUpright), 270, 240, 0.25, 0.125);

    // The mapping uses the orientation even when rotating preserves dimensions.
    ZXScreenFrame square = ZXScreenFrameForPortrait(1400, 1400, ZXFrameRotatedLeft);
    assert(square.width == 1400 && square.height == 1400);
    expect_point(square, 350, 700, 0.5, 0.25);
    expect_point(ZXScreenFrameForPortrait(1000, 3000, ZXFrameUpright), 100, 2700, 0.1, 0.9);
    expect_point(portrait, -10, 2500, 0.0, 1.0);
}
