# Fixed jsoncpp 1.9.5 sources are built with the module; no system dependency.
KARING_ROOT := vendor/karing
KARING_FILES := $(KARING_ROOT)/src/KaringProtocol.cpp \
    $(KARING_ROOT)/src/TVKaringClient.mm \
    $(KARING_ROOT)/src/TVNCKaringService.mm \
    $(KARING_ROOT)/third_party/jsoncpp-src/json_reader.cpp \
    $(KARING_ROOT)/third_party/jsoncpp-src/json_value.cpp \
    $(KARING_ROOT)/third_party/jsoncpp-src/json_writer.cpp
KARING_CFLAGS := -I$(KARING_ROOT)/include -I$(KARING_ROOT)/third_party
