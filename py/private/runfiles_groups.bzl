"""Describe Python runtime contents for language-independent packagers."""

load("@rules_runfiles_group//runfiles_group:describe.bzl", "describe")
load("//py/private:py_info_interop.bzl", "get_transitive_sources", "has_py_info")
load("//py/private/py_venv:types.bzl", "FirstPartyPycInfo", "VirtualenvInfo")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")

def runfiles_group_attrs(name, dependencies, toolchains = []):
    return {
        "_aspect_rule_hints": attr.label_list(default = [Label("//py/private/runfiles_groups:" + name)] + toolchains),
        "_runfiles_group_attrs": attr.string_list(default = dependencies),
    }

def _foreign_python_dependency(ctx, dep):
    content = dep[DefaultInfo].default_runfiles
    if has_py_info(dep):
        content = content.merge(ctx.runfiles(transitive_files = get_transitive_sources(dep)))
    return describe.entry(name = "rules_py#data", content = content, kind = "first_party", rank = describe.RANK_SHARED_DEPS, merge_affinity = "rules_py#data")

def _data_dependency(ctx, dep):
    entry = _foreign_python_dependency(ctx, dep)
    return describe.entry(
        name = dep.label,
        content = entry.content.merge(ctx.runfiles(transitive_files = dep[DefaultInfo].files)),
        kind = "first_party",
        rank = describe.RANK_SHARED_DEPS,
        merge_affinity = "rules_py#data",
    )

def _library(target, ctx):
    dependencies = [
        describe.merge_from("deps", fallback = _foreign_python_dependency),
        describe.merge_from("resolutions", fallback = _foreign_python_dependency),
    ]
    files = target[DefaultInfo].files.to_list()
    separate = ctx.rule.attr.separate_runfiles_group
    sources = files if separate else [file for file in files if file.is_source]
    generated = [] if separate else [file for file in files if not file.is_source]
    return describe.node(
        add = ([describe.entry(
            name = target.label,
            content = depset(sources),
            kind = "first_party",
            rank = describe.RANK_SHARED_DEPS,
            merge_affinity = "" if separate else "rules_py#sources",
            do_not_merge = separate,
        )] if sources else []) + ([describe.entry(
            name = "rules_py#generated:" + str(target.label),
            content = depset(generated),
            kind = "first_party",
            rank = describe.RANK_SHARED_DEPS,
            merge_affinity = "rules_py#generated",
        )] if generated else []),
        merge_from = dependencies + [describe.merge_from("data", fallback = _data_dependency)],
    )

def _bytecode_groups(target, ctx):
    # Use only entries accepted by the venv, preserving ambiguous-path filtering.
    accepted = {entry: True for entry in target[VirtualenvInfo].bytecode_runfiles.symlinks.to_list()}
    groups = {}
    for entry in target[FirstPartyPycInfo].entries.to_list():
        if entry.symlink in accepted:
            groups.setdefault((entry.owner, entry.separate), []).append(entry.symlink)
    return [describe.entry(
        # Protected source layers remain reusable at their producer; their
        # bytecode gets a companion layer. Ordinary source/bytecode groups unite.
        name = "rules_py#bytecode:" + str(owner) if separate else owner,
        content = ctx.runfiles(symlinks = depset(entries)),
        kind = "first_party",
        rank = describe.RANK_SHARED_DEPS,
        merge_affinity = "" if separate else "rules_py#sources",
        do_not_merge = separate,
    ) for (owner, separate), entries in groups.items()]

def _venv(target, ctx):
    content = target[VirtualenvInfo].own_runfiles
    executable = target[DefaultInfo].files_to_run.executable
    if executable:
        content = content.merge(ctx.runfiles(files = [executable]))
    return describe.node(
        add = _bytecode_groups(target, ctx) + [describe.entry(name = target.label, content = content, kind = "first_party")] + ([describe.entry(
            name = "rules_py#wheels:" + str(target.label),
            content = target[VirtualenvInfo].wheel_runfiles,
            kind = "third_party",
            rank = describe.RANK_SHARED_DEPS,
            merge_affinity = "rules_py#wheels",
        )] if target[VirtualenvInfo].wheel_runfiles.files else []),
        merge_from = [
            describe.merge_from("srcs", fallback = _source_dependency),
            describe.merge_from("deps", fallback = _foreign_python_dependency),
            describe.merge_from("data", fallback = _data_dependency),
            describe.merge_from("resolutions", fallback = _foreign_python_dependency),
            describe.merge_from("_runfiles_lib", fallback = "synthesize"),
            describe.merge_from(
                toolchain = Label(PY_TOOLCHAIN),
                fallback = "synthesize",
                into = "rules_py#interpreter",
                kind = "foundation",
                rank = describe.RANK_FOUNDATION,
                do_not_merge = True,
            ),
        ],
    )

def _source_dependency(ctx, dep):
    files = dep[DefaultInfo].files.to_list()

    # Output and generator labels can name the same source. Generated sources
    # may carry runtime data too; keep that closure below the application layer.
    return describe.entry(
        name = files[0].owner if len(files) == 1 else dep.label,
        content = ctx.runfiles(files = files).merge(dep[DefaultInfo].default_runfiles),
        kind = "first_party",
        rank = describe.RANK_SHARED_DEPS,
        merge_affinity = "" if any([not file.is_source for file in files]) else "rules_py#sources",
    )

def _binary(target, ctx):
    venv = ctx.rule.attr.venv
    if type(venv) == "list":
        venv = venv[0]
    content = ctx.runfiles(files = [target[DefaultInfo].files_to_run.executable])
    if ctx.rule.attr.include_console_scripts:
        content = content.merge(ctx.runfiles(transitive_files = venv[VirtualenvInfo].console_scripts))
    return describe.node(
        add = [describe.entry(name = target.label, content = content, kind = "first_party")],
        merge_from = [
            describe.merge_from("venv"),
            describe.merge_from("data", fallback = _data_dependency),
            describe.merge_from("main", fallback = _source_dependency),
        ],
        executable_group = target.label,
    )

def _wheel(target, _ctx):
    return describe.node(add = [describe.entry(
        name = target.label,
        content = target[DefaultInfo].default_runfiles,
        kind = "third_party",
        rank = describe.RANK_SHARED_DEPS,
        merge_affinity = "rules_py#wheels",
    )])

def _interpreter(target, _ctx):
    return describe.node(add = [describe.entry(
        name = target.label,
        content = target[DefaultInfo].files,
        kind = "foundation",
        rank = describe.RANK_FOUNDATION,
        do_not_merge = True,
    )])

library_describer = describe.make_describer_rule(describe = _library)
venv_describer = describe.make_describer_rule(describe = _venv)
binary_describer = describe.make_describer_rule(describe = _binary)
wheel_describer = describe.make_describer_rule(describe = _wheel)
interpreter_describer = describe.make_describer_rule(describe = _interpreter)
