// Small hand-rolled chart primitives for the admin analytics screens — no
// charting package dependency, consistent with CareDial's approach elsewhere
// in the design system.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/care_plus_theme.dart';

/// A smoothed line + soft area fill over normalized (0..1) values, with an
/// optional highlighted last point. Used for revenue/rating trend lines.
class SparkLineChart extends StatelessWidget {
  const SparkLineChart({
    super.key,
    required this.values,
    this.height = 120,
    this.color,
    this.highlightLast = true,
  });

  final List<double> values; // each 0..1
  final double height;
  final Color? color;
  final bool highlightLast;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.scheme.primary;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Motion.ease,
        builder: (_, t, __) => CustomPaint(
          painter: _SparkLinePainter(values, c, context.care.hairline, t, highlightLast),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _SparkLinePainter extends CustomPainter {
  _SparkLinePainter(this.values, this.color, this.grid, this.t, this.highlightLast);
  final List<double> values;
  final Color color, grid;
  final double t;
  final bool highlightLast;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final dx = size.width / (values.length - 1);
    Offset pt(int i) => Offset(dx * i, size.height * (1 - values[i].clamp(0, 1)));

    // Gridlines
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final visibleCount = (values.length * t).clamp(1, values.length).toDouble();
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    final fillPath = Path()..moveTo(pt(0).dx, size.height)..lineTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      if (i > visibleCount) break;
      final p = pt(i);
      path.lineTo(p.dx, p.dy);
      fillPath.lineTo(p.dx, p.dy);
    }
    final lastIndex = math.min(values.length - 1, visibleCount.floor());
    fillPath
      ..lineTo(pt(lastIndex).dx, size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    if (highlightLast) {
      final p = pt(lastIndex);
      canvas.drawCircle(p, 4.5, Paint()..color = color);
      canvas.drawCircle(p, 4.5, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.white.withValues(alpha: 0.9));
    }
  }

  @override
  bool shouldRepaint(_SparkLinePainter old) => old.t != t || old.values != values;
}

/// A ring divided into coloured arcs — one segment per (value, color) slice.
/// Used for payment mix, customer segments, revenue category share.
class DonutChart extends StatelessWidget {
  const DonutChart({
    super.key,
    required this.slices,
    this.size = 120,
    this.stroke = 16,
    this.child,
  });

  final List<(double value, Color color)> slices;
  final double size;
  final double stroke;
  final Widget? child;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 800),
          curve: Motion.ease,
          builder: (_, t, __) => CustomPaint(
            painter: _DonutPainter(slices, stroke, t, context.care.hairline),
            child: Center(child: child),
          ),
        ),
      );
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices, this.stroke, this.t, this.track);
  final List<(double value, Color color)> slices;
  final double stroke, t;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - stroke / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r);
    final total = slices.fold<double>(0, (s, e) => s + e.$1);
    canvas.drawCircle(
        size.center(Offset.zero), r, Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = track);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (final (value, color) in slices) {
      final sweep = (value / total) * 2 * math.pi * t;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt
          ..color = color,
      );
      start += (value / total) * 2 * math.pi;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.t != t || old.slices != slices;
}

/// One row of a ranked/breakdown list: label, trailing value, and a filled
/// bar underneath sized to [fraction] (0..1). Used for leaderboards, category
/// revenue breakdowns, and payment-mix lists.
class HBarRow extends StatelessWidget {
  const HBarRow({
    super.key,
    required this.label,
    required this.value,
    required this.fraction,
    this.color,
    this.rank,
  });

  final String label;
  final String value;
  final double fraction;
  final Color? color;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final barColor = color ?? context.scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (rank != null) ...[
                SizedBox(
                  width: 18,
                  child: Text('$rank',
                      style: CareType.mono(context.care.inkMuted, size: 11, w: FontWeight.w600)),
                ),
              ],
              Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
              Text(value,
                  style: CareType.mono(context.scheme.onSurface, size: 12, w: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: Radii.pill,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction.clamp(0, 1)),
              duration: const Duration(milliseconds: 700),
              curve: Motion.ease,
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: context.care.hairline,
                valueColor: AlwaysStoppedAnimation(barColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Legend dot + label + value, paired with a [DonutChart] to explain slices.
class LegendRow extends StatelessWidget {
  const LegendRow({super.key, required this.color, required this.label, required this.value});
  final Color color;
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 9),
            Expanded(child: Text(label, style: context.type.bodySmall)),
            Text(value, style: CareType.mono(context.scheme.onSurface, size: 11.5, w: FontWeight.w600)),
          ],
        ),
      );
}
