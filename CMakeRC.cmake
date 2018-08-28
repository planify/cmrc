if(_CMRC_GENERATE_MODE)
    # Read in the digits
    file(READ "${INPUT_FILE}" bytes HEX)
    # Format each pair into a character literal. Heuristics seem to favor doing
    # the conversion in groups of five for fastest conversion
    string(REGEX REPLACE "(..)(..)(..)(..)(..)" "'\\\\x\\1','\\\\x\\2','\\\\x\\3','\\\\x\\4','\\\\x\\5'," chars "${bytes}")
    # Since we did this in groups, we have some leftovers to clean up
    string(LENGTH "${bytes}" n_bytes2)
    math(EXPR n_bytes "${n_bytes2} / 2")
    math(EXPR remainder "${n_bytes} % 5") # <-- '5' is the grouping count from above
    set(cleanup_re "$")
    set(cleanup_sub )
    while(remainder)
        set(cleanup_re "(..)${cleanup_re}")
        set(cleanup_sub "'\\\\x\\${remainder}',${cleanup_sub}")
        math(EXPR remainder "${remainder} - 1")
    endwhile()
    if(NOT cleanup_re STREQUAL "$")
        string(REGEX REPLACE "${cleanup_re}" "${cleanup_sub}" chars "${chars}")
    endif()
    string(CONFIGURE [[
        namespace { const char file_array[] = { @chars@ }; }
        namespace cmrc { namespace @LIBRARY@ { namespace res_chars {
        extern const char* const @SYMBOL@_begin = file_array;
        extern const char* const @SYMBOL@_end = file_array + @n_bytes@;
        }}}
    ]] code)
    file(WRITE "${OUTPUT_FILE}" "${code}")
    return()
endif()

if(COMMAND cmrc_add_resource_library)
    # CMakeRC has already been included! Don't do anything
    return()
endif()

set(this_script "${CMAKE_CURRENT_LIST_FILE}")

# CMakeRC uses std::call_once().
set(THREADS_PREFER_PTHREAD_FLAG TRUE)
find_package(Threads REQUIRED)

get_filename_component(_inc_dir "${CMAKE_BINARY_DIR}/_cmrc/include" ABSOLUTE)
set(CMRC_INCLUDE_DIR "${_inc_dir}" CACHE INTERNAL "Directory for CMakeRC include files")
# Let's generate the primary include file
file(MAKE_DIRECTORY "${CMRC_INCLUDE_DIR}/cmrc")
set(hpp_content [==[
#ifndef CMRC_CMRC_HPP_INCLUDED
#define CMRC_CMRC_HPP_INCLUDED

#include <string>
#include <map>
#include <mutex>
#include <deque>
#include <type_traits>
#include <cassert>
#include <functional>
#include <system_error>

namespace cmrc { namespace detail { struct dummy; } }

#define CMRC_DECLARE(libid) \
    namespace cmrc { namespace detail { \
    struct dummy; \
    static_assert(std::is_same<dummy, ::cmrc::detail::dummy>::value, "CMRC_DECLARE() must only appear at the global namespace"); \
    } } \
    namespace cmrc { namespace libid { \
    cmrc::embedded_filesystem get_filesystem(); \
    } } static_assert(true, "")

namespace cmrc {

class file {
    const char* _begin = nullptr;
    const char* _end = nullptr;

public:
    const char* begin() const { return _begin; }
    const char* end() const { return _end; }

    file() = default;
    file(const char* beg, const char* end) : _begin(beg), _end(end) {}
};

namespace detail {

class directory;
class file_data;

class file_or_directory {
    union _data_t {
        class file_data* file_data;
        class directory* directory;
    } _data;
    bool _is_file = true;

public:
    explicit file_or_directory(file_data& f) {
        _data.file_data = &f;
    }
    explicit file_or_directory(directory& d) {
        _data.directory = &d;
        _is_file = false;
    }
    bool is_file() const noexcept {
        return _is_file;
    }
    const directory& as_directory() const noexcept {
        assert(!is_file());
        return *_data.directory;
    }
    const file_data& as_file() const noexcept {
        assert(is_file());
        return *_data.file_data;
    }
};

class file_data {
public:
    const char* begin_ptr;
    const char* end_ptr;
    file_data(const file_data&) = delete;
    file_data(const char* b, const char* e) : begin_ptr(b), end_ptr(e) {}
};

inline std::pair<std::string, std::string> split_path(const std::string& path) {
    auto first_sep = path.find("/");
    if (first_sep == path.npos) {
        return std::make_pair(path, "");
    } else {
        return std::make_pair(path.substr(0, first_sep), path.substr(first_sep));
    }
}

class directory {
    std::deque<file_data> _files;
    std::deque<directory> _dirs;
    std::map<std::string, file_or_directory> _index;
public:
    directory() = default;
    directory(const directory&) = delete;

    directory& add_subdir(std::string name) & {
        _dirs.emplace_back();
        auto& back = _dirs.back();
        _index.emplace(name, back);
        return back;
    }

    void add_file(std::string name, const char* begin, const char* end) & {
        assert(_index.find(name) == _index.end());
        _files.emplace_back(begin, end);
        _index.emplace(name, _files.back());
    }

    const file_or_directory* get(const std::string& path) const {
        auto pair = split_path(path);
        auto child = _index.find(pair.first);
        if (child == _index.end()) {
            return nullptr;
        }
        auto& entry  = child->second;
        if (pair.second.empty()) {
            // We're at the end of the path
            return &entry;
        }

        if (entry.is_file()) {
            // We can't traverse into a file. Stop.
            return nullptr;
        }
        // Keep going down
        return entry.as_directory().get(pair.second);
    }
};

inline std::string normalize_path(std::string path) {
    while (path.find("/") == 0) {
        path.erase(path.begin());
    }
    while (path.rfind("/") == path.size() - 1) {
        path.pop_back();
    }
    auto off = path.npos;
    while ((off = path.find("//")) != path.npos) {
        path.erase(path.begin() + off);
    }
    return path;
}

} // detail

class embedded_filesystem {
    // Never-null:
    const cmrc::detail::directory* _root;
    const detail::file_or_directory* _get(std::string path) const {
        path = detail::normalize_path(path);
        return _root->get(path);
    }
public:
    explicit embedded_filesystem(const cmrc::detail::directory& dir) : _root(&dir) {}

    file open(std::string path) const {
        auto entry_ptr = _get(path);
        if (!entry_ptr || !entry_ptr->is_file()) {
            throw std::system_error(make_error_code(std::errc::no_such_file_or_directory), path);
        }
        auto& dat = entry_ptr->as_file();
        return file{dat.begin_ptr, dat.end_ptr};
    }
};

}

#endif // CMRC_CMRC_HPP_INCLUDED
]==])

set(cmrc_hpp "${CMRC_INCLUDE_DIR}/cmrc/cmrc.hpp" CACHE INTERNAL "")
set(_generate 1)
if(EXISTS "${cmrc_hpp}")
    file(READ "${cmrc_hpp}" _current)
    if(_current STREQUAL hpp_content)
        set(_generate 0)
    endif()
endif()
file(GENERATE OUTPUT "${cmrc_hpp}" CONTENT "${hpp_content}" CONDITION ${_generate})

add_library(cmrc-base INTERFACE)
target_include_directories(cmrc-base INTERFACE "${CMRC_INCLUDE_DIR}")
target_compile_features(cmrc-base INTERFACE cxx_nullptr)
target_link_libraries(cmrc-base INTERFACE Threads::Threads)
set_property(TARGET cmrc-base PROPERTY INTERFACE_CXX_EXTENSIONS OFF)
add_library(cmrc::base ALIAS cmrc-base)

function(cmrc_add_resource_library name)
    set(args ALIAS)
    cmake_parse_arguments(PARSE_ARGV 1 ARG "" "${args}" "")
    # Generate the identifier for the resource library's namespace
    string(MAKE_C_IDENTIFIER "${name}" libident)
    set(libname "${name}")
    # Generate a library with the compiled in character arrays.
    string(CONFIGURE [=[
        #include <cmrc/cmrc.hpp>
        #include <map>

        namespace cmrc {
        namespace @libident@ {

        namespace res_chars {
        // These are the files which are available in this resource library
        $<JOIN:$<TARGET_PROPERTY:@libname@,CMRC_EXTERN_DECLS>,
        >
        }

        namespace {

        cmrc::detail::directory& get_root_dir() {
            static cmrc::detail::directory root_directory;
            $<JOIN:$<TARGET_PROPERTY:@libname@,CMRC_MAKE_DIRS>,
            >
            $<JOIN:$<TARGET_PROPERTY:@libname@,CMRC_MAKE_FILES>,
            >
            return root_directory;
        }

        }

        cmrc::embedded_filesystem get_filesystem() {
            static auto& root_dir = get_root_dir();
            return cmrc::embedded_filesystem{root_dir};
        }

        } // @libident@
        } // cmrc
    ]=] cpp_content @ONLY)
    get_filename_component(libdir "${CMAKE_CURRENT_BINARY_DIR}/${name}" ABSOLUTE)
    get_filename_component(lib_tmp_cpp "${libdir}/lib_.cpp" ABSOLUTE)
    string(REPLACE "\n        " "\n" cpp_content "${cpp_content}")
    file(GENERATE OUTPUT "${lib_tmp_cpp}" CONTENT "${cpp_content}")
    get_filename_component(libcpp "${libdir}/lib.cpp" ABSOLUTE)
    add_custom_command(OUTPUT "${libcpp}"
        DEPENDS "${lib_tmp_cpp}" "${cmrc_hpp}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${lib_tmp_cpp}" "${libcpp}"
        COMMENT "Generating ${name} resource loader"
        )
    # Generate the actual static library. Each source file is just a single file
    # with a character array compiled in containing the contents of the
    # corresponding resource file.
    add_library(${name} STATIC ${libcpp})
    set_property(TARGET ${name} PROPERTY CMRC_LIBDIR "${libdir}")
    target_link_libraries(${name} PUBLIC cmrc::base)
    set_property(TARGET ${name} PROPERTY CMRC_IS_RESOURCE_LIBRARY TRUE)
    if(ARG_ALIAS)
        add_library("${ARG_ALIAS}" ALIAS ${name})
    endif()
    cmrc_add_resources(${name} ${ARG_UNPARSED_ARGUMENTS})
endfunction()

function(_cmrc_register_dirs name dirpath)
    if(dirpath STREQUAL "")
        return()
    endif()
    # Skip this dir if we have already registered it
    get_target_property(registered "${name}" _CMRC_REGISTERED_DIRS)
    if(dirpath IN_LIST registered)
        return()
    endif()
    # Register the parent directory first
    get_filename_component(parent "${dirpath}" DIRECTORY)
    if(NOT parent STREQUAL "")
        _cmrc_register_dirs("${name}" "${parent}")
    endif()
    # Now generate the registration
    set_property(TARGET "${name}" APPEND PROPERTY _CMRC_REGISTERED_DIRS "${dirpath}")
    _cm_encode_fpath(sym "${dirpath}")
    if(parent STREQUAL "")
        set(parent_sym root_directory)
    else()
        _cm_encode_fpath(parent_sym "${parent}")
    endif()
    get_filename_component(leaf "${dirpath}" NAME)
    set_property(
        TARGET "${name}"
        APPEND PROPERTY CMRC_MAKE_DIRS
        "static auto& ${sym} = ${parent_sym}.add_subdir(\"${leaf}\")\;"
        )
endfunction()

function(cmrc_add_resources name)
    get_target_property(is_reslib ${name} CMRC_IS_RESOURCE_LIBRARY)
    if(NOT TARGET ${name} OR NOT is_reslib)
        message(SEND_ERROR "cmrc_add_resources called on target '${name}' which is not an existing resource library")
        return()
    endif()

    set(options)
    set(args WHENCE PREFIX)
    set(list_args)
    cmake_parse_arguments(PARSE_ARGV 1 ARG "${options}" "${args}" "${list_args}")

    if(NOT ARG_WHENCE)
        set(ARG_WHENCE ${CMAKE_CURRENT_SOURCE_DIR})
    endif()

    # Generate the identifier for the resource library's namespace
    string(MAKE_C_IDENTIFIER "${name}" libident)

    get_target_property(libdir ${name} CMRC_LIBDIR)
    get_target_property(target_dir ${name} SOURCE_DIR)
    file(RELATIVE_PATH reldir "${target_dir}" "${CMAKE_CURRENT_SOURCE_DIR}")
    if(reldir MATCHES "^\\.\\.")
        message(SEND_ERROR "Cannot call cmrc_add_resources in a parent directory from the resource library target")
        return()
    endif()

    foreach(input IN LISTS ARG_UNPARSED_ARGUMENTS)
        get_filename_component(abs_in "${input}" ABSOLUTE)
        # Generate a filename based on the input filename that we can put in
        # the intermediate directory.
        file(RELATIVE_PATH relpath "${ARG_WHENCE}" "${abs_in}")
        if(relpath MATCHES "^\\.\\.")
            # For now we just error on files that exist outside of the soure dir.
            message(SEND_ERROR "Cannot add file '${input}': File must be in a subdirectory of ${ARG_WHENCE}")
            continue()
        endif()
        if(ARG_PREFIX AND NOT ARG_PREFIX MATCHES "/$")
            set(ARG_PREFIX "${ARG_PREFIX}/")
        endif()
        get_filename_component(dirpath "${ARG_PREFIX}${relpath}" DIRECTORY)
        _cmrc_register_dirs("${name}" "${dirpath}")
        get_filename_component(abs_out "${libdir}/intermediate/${relpath}.cpp" ABSOLUTE)
        # Generate a symbol name relpath the file's character array
        _cm_encode_fpath(sym "${relpath}")
        # Get the symbol name for the parent directory
        if(dirpath STREQUAL "")
            set(parent_sym root_directory)
        else()
            _cm_encode_fpath(parent_sym "${dirpath}")
        endif()
        # Generate the rule for the intermediate source file
        _cmrc_generate_intermediate_cpp(${libident} ${sym} "${abs_out}" "${abs_in}")
        target_sources(${name} PRIVATE "${abs_out}")
        set_property(TARGET ${name} APPEND PROPERTY CMRC_EXTERN_DECLS
            "// Pointers to ${input}"
            "extern const char* const ${sym}_begin\;"
            "extern const char* const ${sym}_end\;"
            )
        get_filename_component(leaf "${relpath}" NAME)
        set_property(
            TARGET ${name}
            APPEND PROPERTY CMRC_MAKE_FILES
            "${parent_sym}.add_file(\"${leaf}\", res_chars::${sym}_begin, res_chars::${sym}_end)\;"
            )
    endforeach()
endfunction()

function(_cmrc_generate_intermediate_cpp libname symbol outfile infile)
    add_custom_command(
        # This is the file we will generate
        OUTPUT "${outfile}"
        # These are the primary files that affect the output
        DEPENDS "${infile}" "${this_script}"
        COMMAND
            "${CMAKE_COMMAND}"
                -D_CMRC_GENERATE_MODE=TRUE
                -DLIBRARY=${libname}
                -DSYMBOL=${symbol}
                "-DINPUT_FILE=${infile}"
                "-DOUTPUT_FILE=${outfile}"
                -P "${this_script}"
        COMMENT "Generating intermediate file for ${infile}"
    )
endfunction()

function(_cm_encode_fpath var fpath)
    string(MAKE_C_IDENTIFIER "${fpath}" ident)
    string(MD5 hash "${fpath}")
    string(SUBSTRING "${hash}" 0 4 hash)
    set(${var} f_${hash}_${ident} PARENT_SCOPE)
endfunction()
