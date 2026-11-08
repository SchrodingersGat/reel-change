import "package:flutter/material.dart";

/// The app logo, spinning - the app's loading indicator.
///
/// Turns anticlockwise, the way the arrow in the logo points. Stays still
/// when the system asks for animations to be removed (accessibility).
class SpinningLogo extends StatefulWidget {
  const SpinningLogo({
    super.key,
    this.size = 96,
    this.imageKey,
    this.semanticLabel = "Loading",
  });

  final double size;

  /// Key for the logo image (for tests).
  final Key? imageKey;

  final String semanticLabel;

  static const Duration turnDuration = Duration(milliseconds: 1600);

  /// Centre of the reel's hub (the small circle) within the logo image.
  ///
  /// In img/logo.svg the hub is at (11.914, 12.878) in the 24 x 24 viewBox
  /// (circle at (-16.392, 4.392), rotated -120 degrees, then translated by
  /// (-0.086, 0.878)); assets/images/logo.png is rendered edge to edge from
  /// it, so the same point is about (254.2, 274.7) px of 512. The logo spins
  /// around this point, not the middle of the image.
  static const Alignment hubAlignment = Alignment(
    11.914 / 12 - 1,
    12.878 / 12 - 1,
  );

  @override
  State<SpinningLogo> createState() => _SpinningLogoState();
}

class _SpinningLogoState extends State<SpinningLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SpinningLogo.turnDuration,
  );

  // One full turn anticlockwise per cycle
  late final Animation<double> _turns = Tween<double>(
    begin: 0,
    end: -1,
  ).animate(_controller);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Transform.translate(
    // Put the hub (not the middle of the image) at the centre of this
    // widget, so the spinning reel stays centred
    offset: Offset(
      -SpinningLogo.hubAlignment.x * widget.size / 2,
      -SpinningLogo.hubAlignment.y * widget.size / 2,
    ),
    child: RotationTransition(
      turns: _turns,
      alignment: SpinningLogo.hubAlignment,
      child: Image.asset(
        "assets/images/logo.png",
        key: widget.imageKey,
        width: widget.size,
        height: widget.size,
        semanticLabel: widget.semanticLabel,
      ),
    ),
  );
}
