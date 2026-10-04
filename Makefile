APP_NAME = TodoNotch
BUNDLE = $(APP_NAME).app
BIN = .build/release/todo-notch

.PHONY: all app icon selftest install run dist clean

all: app

app:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/todo-notch
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/TodoNotch.icns $(BUNDLE)/Contents/Resources/TodoNotch.icns
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - $(BUNDLE)

icon:
	./scripts/make-icns.sh

selftest:
	swift build
	.build/debug/todo-notch --selftest

install: app
	-pkill -x todo-notch
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	open -g /Applications/$(BUNDLE) &

run: app
	open $(BUNDLE)

dist: app
	rm -f $(APP_NAME).zip
	ditto -c -k --keepParent $(BUNDLE) $(APP_NAME).zip

clean:
	rm -rf .build $(BUNDLE) $(APP_NAME).zip
