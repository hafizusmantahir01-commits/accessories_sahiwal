import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Layered shadows that give surfaces visible depth (3D look).
List<BoxShadow> depthShadows(Color tint, {double strength = 1}) => [
      BoxShadow(color: tint.withValues(alpha: 0.10 * strength), blurRadius: 2, offset: const Offset(0, 1)),
      BoxShadow(color: tint.withValues(alpha: 0.14 * strength), blurRadius: 12, offset: const Offset(0, 6)),
      BoxShadow(
        color: tint.withValues(alpha: 0.16 * strength),
        blurRadius: 30,
        spreadRadius: -6,
        offset: const Offset(0, 18),
      ),
    ];

/// Perspective tilt that follows the mouse (laptop) or finger (phone)
/// and springs back when released.
class Tilt3D extends StatefulWidget {
  const Tilt3D({super.key, required this.child, this.maxAngle = 0.12, this.enabled = true, this.hoverScale = 1.02});

  final Widget child;

  /// Maximum rotation in radians at the card edge.
  final double maxAngle;
  final bool enabled;
  final double hoverScale;

  @override
  State<Tilt3D> createState() => _Tilt3DState();
}

class _Tilt3DState extends State<Tilt3D> {
  Offset _tilt = Offset.zero; // -1..1 on each axis
  bool _active = false;

  void _update(Offset local) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
    final dx = ((local.dx / box.size.width) * 2 - 1).clamp(-1.0, 1.0);
    final dy = ((local.dy / box.size.height) * 2 - 1).clamp(-1.0, 1.0);
    setState(() {
      _tilt = Offset(dx, dy);
      _active = true;
    });
  }

  void _reset() {
    if (!mounted) return;
    setState(() {
      _tilt = Offset.zero;
      _active = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return MouseRegion(
      onHover: (e) => _update(e.localPosition),
      onExit: (_) => _reset(),
      child: Listener(
        onPointerDown: (e) => _update(e.localPosition),
        onPointerMove: (e) => _update(e.localPosition),
        onPointerUp: (_) => _reset(),
        onPointerCancel: (_) => _reset(),
        child: TweenAnimationBuilder<Offset>(
          tween: Tween<Offset>(begin: Offset.zero, end: _tilt),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) {
            final matrix = Matrix4.identity()
              ..setEntry(3, 2, 0.0015) // perspective
              ..rotateX(-t.dy * widget.maxAngle)
              ..rotateY(t.dx * widget.maxAngle);
            return Transform(
              alignment: Alignment.center,
              transform: matrix,
              child: AnimatedScale(
                scale: _active ? widget.hoverScale : 1,
                duration: const Duration(milliseconds: 180),
                child: child,
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Raised gradient surface with layered shadows and an optional 3D tilt.
class Card3D extends StatelessWidget {
  const Card3D({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.tilt = true,
    this.colors,
    this.radius = 18,
    this.maxAngle = 0.1,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final bool tilt;

  /// Gradient colours; defaults to a soft white → blue-grey surface.
  final List<Color>? colors;
  final double radius;
  final double maxAngle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final gradient = colors ??
        (dark
            ? [scheme.surfaceContainerHigh, scheme.surfaceContainerLow]
            : const [Colors.white, Color(0xFFEAF0FB)]);
    final shape = BorderRadius.circular(radius);

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradient),
        border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.08 : 0.8)),
        boxShadow: depthShadows(dark ? Colors.black : scheme.primary),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    return tilt ? Tilt3D(maxAngle: maxAngle, child: surface) : surface;
  }
}

/// Gentle continuous 3D swing around the vertical axis (logos, splash).
class Spin3D extends StatefulWidget {
  const Spin3D({super.key, required this.child, this.angle = 0.45, this.period = const Duration(seconds: 4)});
  final Widget child;
  final double angle;
  final Duration period;

  @override
  State<Spin3D> createState() => _Spin3DState();
}

class _Spin3DState extends State<Spin3D> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.value * 2 * math.pi;
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.002)
          ..rotateY(math.sin(t) * widget.angle)
          ..rotateX(math.cos(t) * widget.angle * 0.25);
        return Transform(alignment: Alignment.center, transform: matrix, child: child);
      },
    );
  }
}

/// Deep navy gradient with soft floating "orbs" at different depths.
class Background3D extends StatelessWidget {
  const Background3D({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget orb(double size, Color color) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.35, -0.35),
              colors: [Colors.white.withValues(alpha: 0.55), color, color.withValues(alpha: 0.0)],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        );

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
                       colors: [Color(0xFF06142C), Color(0xFF0B1F3F), Color(0xFF3F5B8C)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
                                Positioned(top: -80, left: -60, child: orb(260, const Color(0x55B08D3C))),
             Positioned(bottom: -120, right: -80, child: orb(340, const Color(0x553F5B8C))),
             Positioned(top: 120, right: 40, child: orb(90, const Color(0x66E2C77E))),
             Positioned(bottom: 160, left: 30, child: orb(60, const Color(0x55B08D3C))),
          child,
        ],
      ),
    );
  }
}

/// Raised round icon badge with a glossy gradient.
class IconBadge3D extends StatelessWidget {
  const IconBadge3D({super.key, required this.icon, required this.color, this.size = 44});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final deep = Color.lerp(color, Colors.black, 0.4)!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.35)!, color, deep],
        ),
        boxShadow: [
          BoxShadow(color: deep.withValues(alpha: 0.8), offset: const Offset(0, 3)),
          BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 8)),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );
  }
}
