.PHONY: all server ios-targets ios-lib ios-xcframework android-targets flutter-check pod-check flutter-bootstrap flutter-rust-android flutter-rust-ios flutter-prepare flutter-run flutter-apk flutter-ipa flutter-ipa-debug flutter-clean apk ipa ipa-debug clean

PATH := $(HOME)/.cargo/bin:$(PATH)
RUSTUP_TOOLCHAIN ?= stable
RUSTC := $(shell rustup which rustc --toolchain $(RUSTUP_TOOLCHAIN))
CARGO := env RUSTC="$(RUSTC)" rustup run $(RUSTUP_TOOLCHAIN) cargo
FLUTTER ?= flutter
FLUTTER_APP ?= mobile/flutter
FLUTTER_PROJECT_NAME ?= m3u8_on_device
FLUTTER_ORG ?= com.m3u8downloader
IOS_XCFRAMEWORK ?= target/MobileFfi.xcframework
ANDROID_NDK_HOME ?= $(or $(ANDROID_NDK_ROOT),$(firstword $(sort $(wildcard $(HOME)/Library/Android/sdk/ndk/*) $(wildcard $(HOME)/Library/Android/sdk/ndk-bundle))))

# ── Flutter mobile client (recommended) ────────────────────────────────────────
flutter-check:
	@command -v $(FLUTTER) >/dev/null 2>&1 || { \
		echo "Flutter SDK not found on PATH."; \
		echo "Install Flutter first, then rerun this command."; \
		exit 1; \
	}

pod-check:
	@command -v pod >/dev/null 2>&1 || { \
		echo "CocoaPods not found on PATH."; \
		echo "Install CocoaPods first (for example: brew install cocoapods)."; \
		exit 1; \
	}

flutter-bootstrap: flutter-check
	@mkdir -p $(FLUTTER_APP)
	@if [ ! -d "$(FLUTTER_APP)/ios" ] || [ ! -d "$(FLUTTER_APP)/android" ]; then \
		echo "Generating Flutter iOS/Android platform shells..."; \
		cd $(FLUTTER_APP) && $(FLUTTER) create . --platforms=android,ios --project-name $(FLUTTER_PROJECT_NAME) --org $(FLUTTER_ORG); \
	fi
	cd $(FLUTTER_APP) && $(FLUTTER) pub get

flutter-rust-android: flutter-bootstrap android-targets
	@test -n "$(ANDROID_NDK_HOME)" && test -d "$(ANDROID_NDK_HOME)" || { \
		echo "Android NDK not found."; \
		echo "Install the NDK via Android Studio or export ANDROID_NDK_HOME."; \
		exit 1; \
	}
	@mkdir -p $(FLUTTER_APP)/android/app/src/main/jniLibs
	env ANDROID_NDK_HOME="$(ANDROID_NDK_HOME)" ANDROID_NDK_ROOT="$(ANDROID_NDK_HOME)" $(CARGO) ndk \
		-t arm64-v8a \
		-t armeabi-v7a \
		-t x86_64 \
		-o $(FLUTTER_APP)/android/app/src/main/jniLibs \
		build --lib --release -p mobile-ffi

flutter-rust-ios: flutter-bootstrap ios-xcframework
	@mkdir -p $(FLUTTER_APP)/ios/Frameworks
	rm -rf $(FLUTTER_APP)/ios/Frameworks/MobileFfi.xcframework
	cp -R $(IOS_XCFRAMEWORK) $(FLUTTER_APP)/ios/Frameworks/MobileFfi.xcframework
	@echo "✅ Copied MobileFfi.xcframework into the Flutter iOS project."

flutter-prepare: flutter-rust-android flutter-rust-ios

flutter-run: flutter-bootstrap
	cd $(FLUTTER_APP) && $(FLUTTER) run

flutter-apk: flutter-rust-android
	cd $(FLUTTER_APP) && $(FLUTTER) build apk

flutter-ipa: pod-check flutter-rust-ios
	rm -rf $(FLUTTER_APP)/build/ios/archive $(FLUTTER_APP)/build/ios/ipa
	cd $(FLUTTER_APP) && $(FLUTTER) build ipa

flutter-ipa-debug: pod-check flutter-rust-ios
	rm -rf $(FLUTTER_APP)/build/ios/archive $(FLUTTER_APP)/build/ios/ipa
	cd $(FLUTTER_APP) && $(FLUTTER) build ipa --export-options-plist=ios/ExportOptions.debugging.plist


apk: flutter-apk

ipa: flutter-ipa

ipa-debug: flutter-ipa-debug

flutter-clean: flutter-check
	cd $(FLUTTER_APP) && $(FLUTTER) clean
	rm -rf $(FLUTTER_APP)/android/app/src/main/jniLibs
	rm -rf $(FLUTTER_APP)/ios/Frameworks/MobileFfi.xcframework

# ── Rust server (desktop / Docker) ─────────────────────────────────────────────
server:
	$(CARGO) build --release -p server

run:
	$(CARGO) run -p server

# ── iOS native artifacts for Flutter ──────────────────────────────────────────
ios-targets:
	rustup target add --toolchain $(RUSTUP_TOOLCHAIN) aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

ios-lib: ios-targets
	$(CARGO) build --lib --release --target aarch64-apple-ios        -p mobile-ffi
	$(CARGO) build --lib --release --target aarch64-apple-ios-sim    -p mobile-ffi
	$(CARGO) build --lib --release --target x86_64-apple-ios         -p mobile-ffi

ios-xcframework: ios-lib
	# Merge simulator slices into a fat binary
	lipo -create \
		target/aarch64-apple-ios-sim/release/libmobile_ffi.a \
		target/x86_64-apple-ios/release/libmobile_ffi.a \
		-output target/libmobile_ffi_sim.a
	# Create XCFramework
	@mkdir -p $(dir $(IOS_XCFRAMEWORK))
	rm -rf $(IOS_XCFRAMEWORK)
	xcodebuild -create-xcframework \
		-library target/aarch64-apple-ios/release/libmobile_ffi.a \
		-library target/libmobile_ffi_sim.a \
		-output $(IOS_XCFRAMEWORK)

# ── Android Rust targets for Flutter ──────────────────────────────────────────
android-targets:
	rustup target add --toolchain $(RUSTUP_TOOLCHAIN) \
		aarch64-linux-android \
		armv7-linux-androideabi \
		x86_64-linux-android \
		i686-linux-android

# ── Setup ──────────────────────────────────────────────────────────────────────
setup:
	@command -v rustup >/dev/null 2>&1 || { \
		echo "Installing rustup via Homebrew..."; \
		brew install rustup-init; \
		rustup default stable; \
	}
	@rustup show active-toolchain >/dev/null 2>&1 || rustup default $(RUSTUP_TOOLCHAIN)
	$(CARGO) install cargo-ndk
	rustup target add --toolchain $(RUSTUP_TOOLCHAIN) \
		aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
		aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
	@echo "✅ Setup complete. uniffi-bindgen is invoked from source (no install needed)."

clean:
	$(CARGO) clean
	rm -rf $(IOS_XCFRAMEWORK)
	rm -rf target/libmobile_ffi_sim.a
	rm -rf mobile/flutter/build
