import 'package:flutter/material.dart';
import '../config/colors.dart';

class PlaceholderImage extends StatelessWidget {
  final double? width;
  final double? height;
  final double iconSize;

  const PlaceholderImage({
    super.key,
    this.width,
    this.height,
    this.iconSize = 32,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: AppColors.placeholder,
      child: Center(
        child: Icon(
          Icons.camera_alt,
          color: AppColors.textSecondary,
          size: iconSize,
        ),
      ),
    );
  }
}
