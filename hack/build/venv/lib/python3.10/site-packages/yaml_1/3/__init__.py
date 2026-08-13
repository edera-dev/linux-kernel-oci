# coding: utf-8

from __future__ import print_function, absolute_import, division, unicode_literals

_package_data = dict(
    full_package_name='yaml_1.3',
    version_info=(0, 1, 0),
    __version__='0.1.0',
    author='Anthon van der Neut',
    author_email='a.van.der.neut@ruamel.eu',
    description='next YAML parser',
    keywords='pypi statistics',
    entry_points='yaml_1_3=yaml_1_3.__main__:main',
    # entry_points=None,
    license='Copyright Ruamel bvba 2007-2017',
    since=2017,
    # status="α|β|stable",  # the package status on PyPI
    # data_files="",
    # universal=True,
    install_requires=['ruamel.appconfig', 'ruamel.std.argparse>=0.8'],
        # py27=["ruamel.ordereddict"],
    tox=dict(
        env='23',  # *->all p->pypy
    ),
)


version_info = _package_data['version_info']
__version__ = _package_data['__version__']
