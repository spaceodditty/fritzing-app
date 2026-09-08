# SPACE ODDITTY macOS 로컬 빌드

이 경로는 Apple Silicon Mac에서 현재 checkout을 재현 가능한 dependency 조합으로 빌드한다. 모든 다운로드, source checkout, build output은 Git에서 제외된 `.build/`에 둔다. Homebrew의 최신 Qt를 자동으로 사용하지 않는다.

## 고정된 조합

`phoenix.pro`가 요구하는 버전을 기준으로 다음 조합을 고정했다.

| 구성요소 | 고정값 | 검증 방식 |
|---|---:|---|
| Qt | 6.10.3 `clang_64` | `aqtinstall`의 Qt archive 검증과 `qmake -query QT_VERSION` |
| Boost | 1.85.0 | 공식 archive SHA-256 |
| libgit2 | 1.7.1 | tag가 가리키는 commit `a2bde637…` |
| ngspice | 42 | release archive SHA-256 |
| QuaZip | 1.4 INTUISPHERE fork | Fritzing source에 명시된 PR fork commit `b6943c31…` |
| svgpp | 1.3.1 | tag commit `fda1fd88…` |
| Clipper1 | 6.4.2 | SourceForge archive SHA-256 |
| fritzing-parts | `master` snapshot | commit `e64ffe97…` |

compiled dependencies는 Apple Silicon용 `arm64`로 빌드한다. `phoenix.pro`의 기본 universal 설정은 build 스크립트가 qmake의 `-after QMAKE_APPLE_DEVICE_ARCHS=arm64`로 좁힌다. setup 스크립트는 각 native library의 `arm64` slice와 Mach-O 최소 macOS version을 확인한다. Qt 6.10의 공식 macOS binary가 요구하는 최소 target에 맞춰 기본 deployment target은 macOS 13.0이다.

## 준비와 빌드

full Xcode가 설치되고 `xcode-select`로 해당 Developer directory가 선택된 Apple Silicon Mac에서 실행한다.

```bash
tools/setup-macos-build.sh --check
tools/setup-macos-build.sh
tools/build-macos-local.sh --configure-only
tools/build-macos-local.sh
```

첫 setup은 Qt와 dependency source를 내려받고 로컬에서 library를 빌드하므로 시간이 걸린다. 다시 실행하면 검증된 download와 build tree를 재사용한다. archive checksum이 다르거나 Git checkout에 로컬 변경이 있으면 진행을 중단한다.

ngspice 42에 포함된 cppduals는 최신 libc++에서 금지한 `std::is_compound` specialization을 포함한다. setup은 해당 specialization을 제거하는 고정 patch를 적용한다. class type인 `duals::dual<T>`는 표준 trait 자체가 compound type으로 판정하므로 의미는 유지된다.

Qt 6.8.3은 macOS 26에서 `QMacAccessibilityElement`의 reference-count 오류로 `EXC_BAD_ACCESS`가 재현되어 사용하지 않는다. Qt의 [`QTBUG-134784` 수정](https://github.com/qt/qtbase/commit/b1ed5f656f064e553b33752f8e87d2f5b9553e38)은 cached accessibility element의 retain/release 균형을 바로잡으며 Qt 6.8과 6.9로 backport하도록 작성됐다. 이 build는 [macOS 26을 공식 지원하는 Qt 6.10](https://doc.qt.io/qt-6.10/supported-platforms.html)의 최신 공개 patch release인 6.10.3을 사용한다.

Qt 6.10.3의 ARM yield header도 Xcode 26에서 `QTBUG-145239`에 해당하는 compile error를 낸다. local build script는 C++ compile에 `<arm_acle.h>`를 선행 include해 Qt 설치 파일을 바꾸지 않고 이 조합을 처리한다.

결과는 `.build/macos/release64/Fritzing.app`에 생긴다. build 스크립트는 로컬 실행에 필요한 parts, help, translation, ngspice 파일을 bundle 안에서 로컬 checkout으로 연결하고, 생성한 executable의 `--version` smoke test를 수행한다.

```bash
open .build/macos/release64/Fritzing.app
```

## Applications용 bundle 만들기

`release64/Fritzing.app`은 빠른 개발 반복을 위한 절대경로 symlink와 rpath를 사용하므로 그대로 옮기지 않는다. 다음 명령은 Qt framework, QuaZip, ngspice, parts와 지원 자료를 실제 bundle 안에 복사하고, parts database와 `.qm` 번역을 생성하며, third-party bins를 포함한다. 배포된 Mach-O는 arm64로 정리하고 외부 build 경로를 검사한 뒤 ad-hoc 서명과 실행 검사를 수행한다.

```bash
tools/package-macos-local.sh
```

결과는 `.build/macos/installable/Fritzing.app`이다. 지원 자료는 Fritzing이 macOS에서 탐색하는 `Contents/Resources`에 담는다. 패키징은 각 Mach-O의 실제 최소 macOS version이 `Info.plist`의 target보다 높지 않은지도 검사한다. `codesign --verify --deep --strict`, `--version`, runtime 안정성 검사가 통과한 이 복사본만 `/Applications`에 설치한다. ad-hoc 서명은 이 Mac의 로컬 사용을 위한 것이며 Apple Developer ID 서명이나 notarization을 대신하지 않는다.

고정한 `fritzing-parts` snapshot의 `obsolete/Arduino Nano_v30.fzp`에는 같은 XML element에 `replacedby` 속성이 두 번 선언된 upstream data 오류가 있다. parts database 생성 시 이 obsolete part의 parse warning이 출력되지만 생성 작업은 계속된다. 패키징은 `parts.db` 존재 여부와 SQLite `integrity_check` 결과가 `ok`인지 확인하며, 공식 snapshot을 임의로 고치지 않는다.

`FRITZING_BUILD_ROOT`로 `.build/` 위치를 바꿀 수 있다. 상대경로는 repository root를 기준으로 해석하며, qmake 제약 때문에 공백이 든 경로는 거부한다. 최소 배포 대상을 바꾸려면 setup 실행 전에 `MACOSX_DEPLOYMENT_TARGET`을 export한다. setup이 기록한 target은 app qmake에도 적용되며, build 시 다른 값을 주면 중단한다. 이 값을 바꾼 뒤에는 별도의 빈 build root를 사용해 dependency부터 다시 준비한다.

## 공식 배포본과의 경계

이 결과는 개발용 로컬 bundle이다. 공식 배포본과 같은 source commit을 checkout하더라도 다음 항목은 동일하다고 볼 수 없다.

- Fritzing 공식 signing identity와 Apple notarization을 적용하지 않는다.
- `release64` 개발 bundle은 runtime 자료를 절대경로 symlink로 연결하므로 옮길 수 없다. 이동 가능한 결과는 별도로 만든 `installable` bundle이다.
- 공식 release CI의 Xcode, SDK, compiler flag, dependency binary provenance는 공개 source만으로 완전히 재현되지 않는다.
- Qt 6.10.3은 현재 source가 허용하는 `6.5.3`–`6.10.10` 범위에서 고정한 studio build 선택이다.
- parts는 setup 시점의 이동 가능한 branch가 아니라 문서에 적힌 commit으로 고정한다.
- 이 스크립트는 DMG 제작이나 외부 배포를 수행하지 않는다.

따라서 이 bundle은 SPACE ODDITTY 내부 기능 확인과 변경 검증에 사용한다. 공식 Fritzing 바이너리와의 동일성 판정에는 별도의 binary metadata, bundled library, 동작 비교가 필요하다.
