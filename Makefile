# akari — build entry points.
#
#   make build    编译两侧（swift build + bun install）
#   make run      同时启动 core 与 app
#   make clean    删除构建产物
#
# 详细约定见 docs/spec.md 与 docs/protocol.md。

SHELL := /bin/bash
ROOT  := $(shell pwd)
APP   := $(ROOT)/app
CORE  := $(ROOT)/core

# debug | release
CONFIG ?= debug

BUNDLE     := $(ROOT)/build/akari.app
APP_BINARY := $(APP)/.build/$(CONFIG)/akari

.PHONY: all build build-app build-core run run-app run-core check test app-bundle clean help

all: build

## build ---------------------------------------------------------------------

build: build-core build-app

build-app:
	cd $(APP) && swift build -c $(CONFIG)

build-core:
	cd $(CORE) && bun install

## run -----------------------------------------------------------------------

# core 先起（它是 socket 服务端），app 后连。Ctrl-C 一并收掉。
run: build
	@set -m; \
	cd $(CORE) && bun run src/index.ts & \
	CORE_PID=$$!; \
	trap 'kill $$CORE_PID 2>/dev/null' EXIT INT TERM; \
	sleep 0.5; \
	cd $(APP) && swift run -c $(CONFIG) akari

run-app: build-app
	cd $(APP) && swift run -c $(CONFIG) akari

run-core: build-core
	cd $(CORE) && bun run src/index.ts

test:
	cd $(APP) && swift test
	cd $(CORE) && bun test

## check ---------------------------------------------------------------------

check:
	cd $(APP) && swift build -c $(CONFIG)
	cd $(APP) && swift test
	cd $(CORE) && bun run typecheck
	cd $(CORE) && bun test

## bundle --------------------------------------------------------------------

# 把可执行文件包成 .app。开发期跑裸二进制时 TCC 会把权限归属到终端，
# AXIsProcessTrusted() 直接返回 true —— 权限流程必须用真实 .app 测
# （spec.md §4.4 责任进程陷阱）。
app-bundle: build-app
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(APP_BINARY) $(BUNDLE)/Contents/MacOS/akari
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleName</key><string>akari</string>' \
	  '  <key>CFBundleExecutable</key><string>akari</string>' \
	  '  <key>CFBundleIdentifier</key><string>me.eltonzheng.akari</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>0.1.0</string>' \
	  '  <key>CFBundleVersion</key><string>1</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>26.0</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '  <key>NSMicrophoneUsageDescription</key><string>akari 需要麦克风来听你说话。</string>' \
	  '</dict></plist>' \
	  > $(BUNDLE)/Contents/Info.plist
	@# 形象素材随包走，这样 .app 拷到别处也能找到片子（AppDelegate 先看
	@# Contents/Resources/akari，再退回 <repo>/assets/akari）。
	@if [ -d $(ROOT)/assets/akari ]; then cp -R $(ROOT)/assets/akari $(BUNDLE)/Contents/Resources/akari; fi
	@# core 也随包走，而且这一条是安全要求不是便利：发布版只肯执行
	@# Contents/Resources/core，绝不向上搜目录找 core/package.json —— .app
	@# 旁边的目录是谁放的谁说了算（CoreProcess.resolveCoreDirectory）。
	@# 运行时零依赖，所以 node_modules（只有 typescript 与类型定义）不进包。
	mkdir -p $(BUNDLE)/Contents/Resources/core
	cp $(CORE)/package.json $(CORE)/tsconfig.json $(CORE)/bun.lock $(BUNDLE)/Contents/Resources/core/
	cp -R $(CORE)/src $(BUNDLE)/Contents/Resources/core/src
	@echo "built $(BUNDLE)"

## clean ---------------------------------------------------------------------

clean:
	rm -rf $(APP)/.build
	rm -rf $(CORE)/node_modules
	rm -rf $(ROOT)/build

help:
	@grep -E '^[a-z-]+:' $(firstword $(MAKEFILE_LIST)) | cut -d: -f1 | sort -u
