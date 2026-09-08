# Copyright (c) 2021 Fritzing GmbH

message("Using fritzing svgpp detect script.")

defined(svgpp_root, var) {
	SVGPPPATH = $$absolute_path($$svgpp_root)
} else {
	SVGPPPATH = $$absolute_path($$PWD/../../svgpp-1.3.1)
}

exists($$SVGPPPATH/include) {
	message("found svgpp in $${SVGPPPATH}")
} else {
	error("svgpp include path not found in $${SVGPPPATH}/include")
}

message("including $$absolute_path($${SVGPPPATH}/include)")
INCLUDEPATH += $$absolute_path($${SVGPPPATH}/include)
