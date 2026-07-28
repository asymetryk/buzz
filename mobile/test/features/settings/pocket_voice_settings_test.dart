import 'dart:io';

import 'package:buzz/features/settings/settings_page.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/voice/pocket_model_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/widget_helpers.dart';

void main() {
  testWidgets('shows post-install Pocket model download details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Buzz',
      packageName: 'xyz.block.buzz.mobile',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final preferences = await SharedPreferences.getInstance();
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        ))
        .load();
    const screenshotKey = Key('pocket-voice-settings-screenshot');
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      WidgetHelpers.testable(
        overrides: [
          savedPrefsProvider.overrideWithValue(preferences),
          pocketModelProvider.overrideWith(_AbsentPocketModelNotifier.new),
        ],
        child: const RepaintBoundary(
          key: screenshotKey,
          child: SettingsPage(profileHeader: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Pocket voice'), findsOneWidget);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.textContaining('Downloads 440 MB'), findsOneWidget);
    expect(find.text('440 MB'), findsOneWidget);

    // Flutter's text rasterization differs between macOS and the Linux CI
    // runner even with the same bundled fonts. Keep the pixel baseline on the
    // platform that produces the reviewer screenshot; the assertions above
    // remain the cross-platform contract for the download state.
    if (Platform.isMacOS) {
      await expectLater(
        find.byKey(screenshotKey),
        matchesGoldenFile('goldens/pocket_voice_settings.png'),
      );
    }
  });
}

class _AbsentPocketModelNotifier extends PocketModelNotifier {
  @override
  PocketModelState build() =>
      const PocketModelState(phase: PocketModelPhase.absent);
}
