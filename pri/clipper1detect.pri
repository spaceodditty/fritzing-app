# Copyright (c) 2023 Fritzing GmbH

message("Using fritzing Clipper 1 detect script.")

defined(clipper1_root, var) {
    CLIPPER1 = $$absolute_path($$clipper1_root)
} else {
    CLIPPER1 = $$absolute_path($$PWD/../../Clipper1-6.4.2)
}

exists($$CLIPPER1/include/polyclipping/clipper.hpp) {
    message("found Clipper1 in $${CLIPPER1}")
} else {
    error("Clipper1 include path not found in $${CLIPPER1}/include/polyclipping")
}

message("including $$absolute_path($${CLIPPER1}/include)")
INCLUDEPATH += $$absolute_path($${CLIPPER1}/include/polyclipping)

LIBS += -L$$absolute_path($${CLIPPER1}/lib) -lpolyclipping
QMAKE_RPATHDIR += $$absolute_path($${CLIPPER1}/lib)
