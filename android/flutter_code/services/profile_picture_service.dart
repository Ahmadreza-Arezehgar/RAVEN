import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import '../models/user_model.dart';
import 'api_service.dart';
import 'toast_service.dart';
import '../widgets/liquid_glass_dialog.dart';

/// Service for handling profile picture selection and upload
class ProfilePictureService {
  
  /// Pick image from gallery or camera, crop with circular preview, and upload to server
  static Future<User?> updateProfilePicture({
    required BuildContext context,
    required User currentUser,
    required String token,
    required ImageSource source,
  }) async {
    try {
      // 1️⃣ Pick image
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        // Don't compress here - let cropper handle quality
      );
      
      if (image == null) {
        print('📷 [ProfilePicture] User cancelled image selection');
        return null; // User cancelled
      }
      
      print('📷 [ProfilePicture] Image selected: ${image.path}');
      
      // 2️⃣ Crop with circular preview (Liquid Glass styled)
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: image.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 85,
        maxWidth: 512,
        maxHeight: 512,
        uiSettings: [
          IOSUiSettings(
            title: 'Crop Avatar',
            cancelButtonTitle: 'Cancel',
            doneButtonTitle: 'Done',
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
            rotateButtonsHidden: true,
            aspectRatioPickerButtonHidden: true,
            // ✅ Circular crop UI
            cropStyle: CropStyle.circle,
          ),
          AndroidUiSettings(
            toolbarTitle: 'Crop Avatar',
            toolbarColor: const Color(0xFF000000),
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: const Color(0xFF0A84FF),
            backgroundColor: const Color(0xFF000000),
            initAspectRatio: CropAspectRatioPreset.square,
            lockAspectRatio: true,
            hideBottomControls: false,
            // ✅ Circular crop UI
            cropStyle: CropStyle.circle,
          ),
        ],
      );
      
      if (croppedFile == null) {
        print('📷 [ProfilePicture] User cancelled crop');
        return null; // User cancelled cropping
      }
      
      print('📷 [ProfilePicture] Image cropped: ${croppedFile.path}');
      
      // 3️⃣ Upload cropped image
      final imageUrl = await ApiService.uploadImage(File(croppedFile.path));
      
      if (imageUrl == null) {
        throw Exception('Image upload failed - check logs for details');
      }
      
      print('📷 [ProfilePicture] Image uploaded: $imageUrl');
      
      // 4️⃣ Update user profile with new avatar path
      final success = await ApiService.updateProfilePicture(imageUrl);
      
      if (!success) {
        throw Exception('Failed to update profile with new avatar');
      }
      
      print('✅ [ProfilePicture] Profile updated successfully');
      
      // Return updated user with new avatar URL
      final updatedUser = currentUser.copyWith(
        avatarPath: imageUrl,
      );
      
      return updatedUser;
      
    } catch (e) {
      print('❌ [ProfilePicture] Error: $e');
      ToastService.showError('Failed to update profile picture');
      return null;
    }
  }
  
  /// Show Liquid Glass sheet to choose image source
  static Future<ImageSource?> showImageSourceDialog(BuildContext context) async {
    ImageSource? result;
    
    await LiquidGlassActionSheet.show(
      context: context,
      title: 'Choose Image Source',
      options: [
        LiquidGlassSheetOption(
          label: 'Photo Library',
          icon: Icons.photo_library_rounded,
          iconColor: const Color(0xFF34C759),
          onTap: () => result = ImageSource.gallery,
        ),
        LiquidGlassSheetOption(
          label: 'Take Photo',
          icon: Icons.camera_alt_rounded,
          iconColor: const Color(0xFF0A84FF),
          onTap: () => result = ImageSource.camera,
        ),
      ],
    );
    
    return result;
  }
}
