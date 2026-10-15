JsonCpp 1.9.5 implementation files from the fixed upstream tag:
https://github.com/open-source-parsers/jsoncpp/tree/1.9.5/src/lib_json

Headers are in ../json/. LICENSE is the upstream 1.9.5 license.
This is a compiled library, not a header-only dependency. karing.mk and the
host test builder compile json_reader.cpp, json_value.cpp and json_writer.cpp.
