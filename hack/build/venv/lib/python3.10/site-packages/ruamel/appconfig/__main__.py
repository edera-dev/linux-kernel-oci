# coding: utf-8

from __future__ import print_function
from __future__ import absolute_import

import configobj
import sys
import os                 # NOQA

try:
    import ruamel.yaml
    yaml_available = True
except ImportError:
    yaml_available = False

try:
    import pon
    pon_available = True
except ImportError:
    pon_available = False

from ruamel.std.argparse import ProgramBase, option, CountAction, \
    SmartFormatter, sub_parser, version
# from ruamel.appconfig import AppConfig
from . import __version__


def to_stdout(*args):
    sys.stdout.write(' '.join(args))


class AppConfigCmd(ProgramBase):
    def __init__(self):
        super(AppConfigCmd, self).__init__(
            formatter_class=SmartFormatter,
            # aliases=True,
            # usage="""""",
        )

    # you can put these on __init__, but subclassing Test2Cmd
    # will cause that to break
    @option('--verbose', '-v',
            help='increase verbosity level', action=CountAction,
            const=1, nargs=0, default=0, global_option=True)
    @version('version: ' + __version__)
    def _pb_init(self):
        # special name for which attribs are included in help
        pass

    def run(self):
        if hasattr(self._args, 'func'):  # not there if subparser selected
            return self._args.func()
        self._parse_args(['--help'])     # replace if you use not subparsers

    def parse_args(self):
        self._parse_args(
            # default_sub_parser="",
        )

    if pon_available and yaml_available:
        @sub_parser(help='convert INI/YAML config file to PON')
        @option('config', nargs='+')
        def update(self):
            for c in self._args.config:
                base_name, ext = os.path.splitext(c)
                print('c', c)
                if ext in ['.yaml', '.yml']:
                    data = ruamel.yaml.round_trip_load(open(c))
                elif ext in ['.ini', '.cfg']:
                    data = configobj.ConfigObj(c)

                odata = pon.ordereddict()
                for k in data:
                    if k == 'global':
                        odata['glbl'] = data[k]
                        continue
                    odata[k] = data[k]
                pon_name = base_name + '.pon'
                if not os.path.exists(pon_name):
                    pd = pon.PON(obj=odata)
                    with open(pon_name, 'w') as fp:
                        pd.dump(fp)


def main():
    n = AppConfigCmd()
    n.parse_args()
    sys.exit(n.run())


if __name__ == '__main__':
    main()
