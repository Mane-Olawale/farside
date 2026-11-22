PACKAGES = WireProtocol InputModel MediaCore SecureStore Pairing BackendClient SessionTransport Telemetry HostCapture HostInput ClientVideo ClientInput
PROJECT = Farside.xcodeproj
DERIVED = .build/DerivedData
XCB = xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

.PHONY: generate test ci build build-client build-host run-host install-client build-testpattern run-testpattern build-loopback run-s1 build-inputprobe run-s2 build-s3 run-s3-local install-s3-viewer build-lockprobe build-permprobe proto proto-check hooks server-up

generate:
	xcodegen generate

# Packages with a Tests directory run their tests. The rest only have to build.
test:
	@for package in $(PACKAGES); do \
		echo "==> $$package"; \
		if [ -d Packages/$$package/Tests ]; then \
			swift test --package-path Packages/$$package || exit 1; \
		else \
			swift build --package-path Packages/$$package || exit 1; \
		fi; \
	done

# What CI runs (.github/workflows/ci.yml): package tests, then both app builds.
ci: test build-client build-host

build: build-client build-host build-testpattern

build-client: generate
	$(XCB) -scheme Client -destination 'generic/platform=iOS' build

build-host: generate
	$(XCB) -scheme Host -destination 'generic/platform=macOS' build

# Signed with the team in Config/Local.xcconfig, so Screen Recording and Local Network grants
# survive rebuilds (plan section 6, development notes). Release, as it will be measured.
run-host: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme Host -configuration Release \
		-destination 'generic/platform=macOS' -allowProvisioningUpdates build
	open "$(DERIVED)/Build/Products/Release/Farside Host.app"

# IPAD is the device identifier from `xcrun devicectl list devices`.
install-client: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme Client -configuration Release \
		-destination 'generic/platform=iOS' -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(IPAD) $(DERIVED)/Build/Products/Release-iphoneos/Farside.app

build-testpattern: generate
	$(XCB) -scheme TestPattern -destination 'generic/platform=macOS' build

run-testpattern: build-testpattern
	open $(DERIVED)/Build/Products/Debug/TestPattern.app

# Signed with the team in Config/Local.xcconfig, so the Screen Recording grant survives rebuilds.
# Release, because the spike measures the pipeline's real speed.
build-loopback: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme Loopback -configuration Release \
		-destination 'generic/platform=macOS' -allowProvisioningUpdates build

# One timed S1 run per codec. Reports land in ~/Library/Logs/Farside.
run-s1: build-loopback
	open -W $(DERIVED)/Build/Products/Release/Loopback.app --args --codec hevc --duration 30
	open -W $(DERIVED)/Build/Products/Release/Loopback.app --args --codec h264 --duration 30

# Signed like the loopback, so the Accessibility grant survives rebuilds.
build-inputprobe: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme InputProbe -configuration Release \
		-destination 'generic/platform=macOS' -allowProvisioningUpdates build

# Takes about a minute and moves the pointer. Keep hands off the keyboard and mouse.
run-s2: build-inputprobe
	open -W $(DERIVED)/Build/Products/Release/InputProbe.app

# Spike S3. The host captures and sends over WebRTC; the viewer runs on an iPad.
build-s3: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme S3Host -configuration Release \
		-destination 'generic/platform=macOS' -allowProvisioningUpdates build

# In-process receiver, one run per playout mode.
run-s3-local: build-s3
	for p in standard receiverZero senderZero both; do \
		open -W $(DERIVED)/Build/Products/Release/S3Host.app --args --mode local --playout $$p --duration 15; \
	done

# IPAD is the device identifier from `xcrun devicectl list devices`.
install-s3-viewer: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme S3Viewer -configuration Release \
		-destination 'generic/platform=iOS' -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(IPAD) $(DERIVED)/Build/Products/Release-iphoneos/S3Viewer.app

# Spike S5. Locks the Mac; run it only when you are at the keyboard.
build-lockprobe: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme LockProbe -configuration Release \
		-destination 'generic/platform=macOS' -allowProvisioningUpdates build

# Spike S6.
build-permprobe: generate
	xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -scheme PermissionProbe -configuration Release \
		-destination 'generic/platform=macOS' -allowProvisioningUpdates build

# Regenerates Swift from Packages/WireProtocol/Proto. Generated code is committed (plan section 5).
# protoc-gen-swift is built from the swift-protobuf version pinned in WireProtocol's manifest, so
# the generator always matches the runtime library. The plugin path is explicit, so a copy on PATH
# (for example from Homebrew) is never used.
PROTOC ?= /usr/local/bin/protoc
PROTO_DIR = Packages/WireProtocol/Proto
PROTO_OUT = Packages/WireProtocol/Sources/WireProtocol/Generated

proto:
	swift build -c release --package-path Packages/WireProtocol --product protoc-gen-swift
	mkdir -p $(PROTO_OUT)
	rm -f $(PROTO_OUT)/*.pb.swift
	$(PROTOC) --plugin=protoc-gen-swift="$$(swift build -c release --package-path Packages/WireProtocol --show-bin-path)/protoc-gen-swift" \
		--proto_path=$(PROTO_DIR) \
		--swift_opt=Visibility=Public \
		--swift_out=$(PROTO_OUT) \
		$(PROTO_DIR)/*.proto

# CI: fails if the committed generated code differs from what `make proto` produces.
proto-check: proto
	@if [ -n "$$(git status --porcelain -- $(PROTO_OUT))" ]; then \
		echo "Generated protocol code is out of date. Run make proto and commit the result."; \
		git status --porcelain -- $(PROTO_OUT); \
		exit 1; \
	fi

hooks:
	mkdir -p .git/hooks
	cp Tools/git-hooks/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit Tools/git-hooks/pre-commit

server-up:
	@if [ ! -f Server/deploy/compose.yml ]; then \
		echo "No Server/deploy/compose.yml yet. The backend arrives in Phase 3."; exit 0; \
	fi; \
	docker compose -f Server/deploy/compose.yml up -d
