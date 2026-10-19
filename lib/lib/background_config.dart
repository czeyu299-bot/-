dart
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';

enum BgType { color, gradient, image }

class BackgroundConfig {
  BgType type;
  Color color;
  List<Color> gradient;
  String? imagePath;
  double opacity;
  double blur;

  BackgroundConfig({
    this.type = BgType.gradient,
    this.color = const Color(0xFFF1F5FB),
    this.gradient = const [Color(0xFFE8F0FE), Color(0xFFF7F9FC)],
    this.imagePath,
    this.opacity = 0.85,
    this.blur = 0,
  });

  Map<String, String> toMap() => {
        'type': type.name,
        'color': color.value.toString(),
        'grad1': gradient[0].value.toString(),
        'grad2': gradient.length > 1
            ? gradient[1].value.toString()
            : gradient[0].value.toString(),
        'image': imagePath ?? '',
        'opacity': opacity.toString(),
        'blur': blur.toString(),
      };

  static BackgroundConfig fromMap(Map<String, String?> m) {
    Color c(String? v, Color fallback) =>
        v == null ? fallback : Color(int.tryParse(v) ?? fallback.value);
    return BackgroundConfig(
      type: BgType.values.firstWhere(
        (e) => e.name == m['type'],
        orElse: () => BgType.gradient,
      ),
      color: c(m['color'], const Color(0xFFF1F5FB)),
      gradient: [
        c(m['grad1'], const Color(0xFFE8F0FE)),
        c(m['grad2'], const Color(0xFFF7F9FC)),
      ],
      imagePath: (m['image']?.isEmpty ?? true) ? null : m['image'],
      opacity: double.tryParse(m['opacity'] ?? '') ?? 0.85,
      blur: double.tryParse(m['blur'] ?? '') ?? 0,
    );
  }
}

class AppBackground extends StatelessWidget {
  final BackgroundConfig config;
  final Widget child;

  const AppBackground({super.key, required this.config, required this.child});

  @override
  Widget build(BuildContext context) {
    Widget bg;
    switch (config.type) {
      case BgType.color:
        bg = Container(color: config.color);
        break;
      case BgType.gradient:
        bg = Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: config.gradient.length > 1
                  ? config.gradient
                  : [config.gradient[0], config.gradient[0]],
            ),
          ),
        );
        break;
      case BgType.image:
        final path = config.imagePath;
        if (path != null && File(path).existsSync()) {
          bg = Image.file(
            File(path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );
          if (config.blur > 0) {
            bg = ImageFiltered(
              imageFilter:
                  ImageFilter.blur(sigmaX: config.blur, sigmaY: config.blur),
              child: bg,
            );
          }
        } else {
          bg = Container(color: const Color(0xFFF1F5FB));
        }
        break;
    }

    return Stack(
      children: [
        Positioned.fill(child: bg),
        Positioned.fill(
          child: Container(
            color: Colors.white
                .withOpacity((1 - config.opacity).clamp(0.0, 1.0)),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
