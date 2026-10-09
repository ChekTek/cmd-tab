APP         = CmdTab
BUILD_DIR   = .build/release
APP_DIR     = build/$(APP).app
INSTALL_DIR = $(HOME)/Applications
# A stable signing identity keeps the Accessibility / Screen Recording grants across rebuilds.
# Ad-hoc ("-") works too, but macOS treats every rebuild as a new app and the grants must be re-done.
SIGN_ID    ?= Apple Development

.PHONY: build bundle install run stop restore clean

build:
	swift build -c release

bundle: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp "$(BUILD_DIR)/$(APP)" "$(APP_DIR)/Contents/MacOS/"
	cp Info.plist "$(APP_DIR)/Contents/"
	codesign --force --sign "$(SIGN_ID)" "$(APP_DIR)"

install: bundle stop
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP).app"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP).app"

run: bundle stop
	open "$(APP_DIR)"

stop:
	-pkill -x $(APP)

# If the app ever dies without re-enabling the system's own ⌘⇥, this puts it back.
restore:
	"$(INSTALL_DIR)/$(APP).app/Contents/MacOS/$(APP)" --restore

clean:
	rm -rf .build build
