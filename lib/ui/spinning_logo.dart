import "package:flutter/material.dart";

/// The reel from the app logo (without its arrow), spinning - the app's
/// loading indicator.
///
/// Turns anticlockwise, the way the arrow in the logo points. Stays still
/// when the system asks for animations to be removed (accessibility).
///
/// assets/images/reel.png is rendered from img/reel.svg: the logo without the
/// arrow, with its viewBox centred on the reel's hub - so the reel turns
/// about the middle of the image.
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

  static const String reelAsset = "assets/images/reel.png";

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
  Widget build(BuildContext context) => RotationTransition(
    turns: _turns,
    child: Image.asset(
      SpinningLogo.reelAsset,
      key: widget.imageKey,
      width: widget.size,
      height: widget.size,
      semanticLabel: widget.semanticLabel,
    ),
  );
}
