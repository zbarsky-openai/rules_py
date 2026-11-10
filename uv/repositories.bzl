"""TOML and JSON inputs for uv project resolution."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")

def _toml_to_json(ctx, src):
    tool = Label("@toml2json_%s//file:downloaded" % repo_utils.platform(ctx))
    ctx.watch(tool)
    ctx.watch(src)
    result = ctx.execute([tool, src])
    if result.return_code:
        fail("Unable to decode TOML file %s" % src)
    return result.stdout

def read_toml_or_json(ctx, src):
    """Decode a uv input, including JSON already converted by toml_inputs."""
    content = ctx.read(src) if src.name.endswith(".json") else _toml_to_json(ctx, src)
    return json.decode(content)

def _toml_inputs_impl(ctx):
    for output, src in ctx.attr.files.items():
        ctx.file(output, _toml_to_json(ctx, src), executable = False)
    ctx.file("BUILD.bazel", "exports_files({})".format(ctx.attr.files.keys()), executable = False)
    return ctx.repo_metadata(reproducible = True)

toml_inputs = repository_rule(
    implementation = _toml_inputs_impl,
    attrs = {
        "files": attr.string_keyed_label_dict(
            mandatory = True,
            doc = "Map .json output filenames to TOML source labels.",
        ),
    },
    doc = """Cache TOML conversion for files that change together. Pass the resulting
JSON labels to uv.project, uv.annotate_packages, and lock-scoped overrides.""",
)
