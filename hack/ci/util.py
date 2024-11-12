def format_image_name(repository, flavor, version_info, name, tag):
    result = repository
    result = result.replace("[image]", name)
    result = result.replace("[flavor]", flavor)
    result = result.replace("[major]", str(version_info.major))
    result = result.replace("[minor]", str(version_info.minor))
    result = result.replace("[patch]", str(version_info.micro))
    result = result.replace(
        "[series]", "%s.%s" % (version_info.major, version_info.minor)
    )
    result = result.replace("[tag]", tag)
    return result
