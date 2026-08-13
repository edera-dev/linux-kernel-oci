# coding: utf-8

from __future__ import print_function

_package_data = dict(
    full_package_name='ruamel.std.argparse',
    version_info=(0, 8, 3),
    __version__='0.8.3',
    author='Anthon van der Neut',
    author_email='a.van.der.neut@ruamel.eu',
    description='Enhancements to argparse: extra actions, subparser aliases, smart formatter, a decorator based wrapper',  # NOQA
    entry_points=None,
    since=2007,
    keywords='argparse enhanced',
    install_requires=[],
    universal=True,
    tox=dict(env='*p'),
    print_allowed=True,
)

version_info = _package_data['version_info']
__version__ = _package_data['__version__']

import sys                           # NOQA
import os                            # NOQA
import argparse                      # NOQA
from argparse import ArgumentParser  # NOQA
import glob                          # NOQA
from importlib import import_module  # NOQA
from argparse import SUPPRESS  # NOQA

PY3 = sys.version_info[0] == 3

if PY3:
    string_types = str,
else:
    string_types = basestring,  # NOQA

store_true = 'store_true'
store_false = 'store_false'
append = 'append'


class SubParsersAction(argparse._SubParsersAction):
    """support aliases, based on differences of 3.3 and 2.7

    install with:
        if sys.version_info < (3,):  # add aliases support
            self._argparser.register('action', 'parsers', SubParsersAction)
    """
    class _AliasesChoicesPseudoAction(argparse.Action):

        def __init__(self, name, aliases, help):
            metavar = dest = name
            if aliases:
                metavar += ' (%s)' % ', '.join(aliases)
            sup = super(SubParsersAction._AliasesChoicesPseudoAction, self)
            sup.__init__(option_strings=[], dest=dest, help=help,
                         metavar=metavar)

    def add_parser(self, name, **kwargs):
        # remove aliases and help kwargs so the orginal add_parser
        # does not get them
        aliases = kwargs.pop('aliases', ())
        help = kwargs.pop('help', None)
        parser = argparse._SubParsersAction.add_parser(self, name, **kwargs)

        if help is not None:
            choice_action = self._AliasesChoicesPseudoAction(name, aliases,
                                                             help)
            self._choices_actions.append(choice_action)
        if aliases is not None:
            for alias in aliases:
                self._name_parser_map[alias] = parser

        return parser


from .action.checksinglestore import CheckSingleStoreAction  # NOQA
from .action.count import CountAction                        # NOQA
from .action.date import DateAction                          # NOQA
from .action.splitappend import SplitAppendAction            # NOQA


class SmartFormatter(argparse.HelpFormatter):
    """
    you can only specify one formatter in standard argparse, so you cannot
    both have pre-formatted description (RawDescriptionHelpFormatter)
    and ArgumentDefaultsHelpFormatter.
    The SmartFormatter has sensible defaults (RawDescriptionFormatter) and
    the individual help text can be marked ( help="R|" ) for
    variations in formatting.
    version string is formatted using _split_lines and preserves any
    line breaks in the version string.
    """
    def __init__(self, *args, **kw):
        self._add_defaults = None
        super(SmartFormatter, self).__init__(*args, **kw)

    def _fill_text(self, text, width, indent):
        return ''.join([indent + line for line in text.splitlines(True)])

    def _split_lines(self, text, width):
        if text.startswith('D|'):
            self._add_defaults = True
            text = text[2:]
        elif text.startswith('*|'):
            text = text[2:]
        if text.startswith('R|'):
            return text[2:].splitlines()
        return argparse.HelpFormatter._split_lines(self, text, width)

    def _get_help_string(self, action):
        if self._add_defaults is None:
            return argparse.HelpFormatter._get_help_string(self, action)
        help = action.help
        if '%(default)' not in action.help:
            if action.default is not argparse.SUPPRESS:
                defaulting_nargs = [argparse.OPTIONAL, argparse.ZERO_OR_MORE]
                if action.option_strings or action.nargs in defaulting_nargs:
                    help += ' (default: %(default)s)'
        return help

    def _expand_help(self, action):
        """mark a password help with '*|' at the start, so that
        when global default adding is activated (e.g. through a helpstring
        starting with 'D|') no password is show by default.
        Orginal marking used in repo cannot be used because of decorators.
        """
        hs = self._get_help_string(action)
        if hs.startswith('*|'):
            params = dict(vars(action), prog=self._prog)
            if params.get('default') is not None:
                # you can update params, this will change the default, but we
                # are printing help only
                params['default'] = '*' * len(params['default'])
            return self._get_help_string(action) % params
        return super(SmartFormatter, self)._expand_help(action)


class ProgramBase(object):
    """
    ToDo:
    - grouping
    - mutual exclusion
    Done:
    - Original order/sorted (by kw)
    - aliases

    """
    _methods_with_sub_parsers = []

    def __init__(self, *args, **kw):
        """
        the 'aliases' keyword does result in the 'aliases' keyword in
        @sub_parser  (as for Py3 in add_parser()) being available for 2.x
        """
        self._verbose = kw.pop('verbose', 0)
        aliases = kw.pop('aliases', 0)
        self._full_package_name = kw.pop('full_package_name', None)
        self._parser = argparse.ArgumentParser(*args, **kw)
        if aliases and sys.version_info < (3,):
            self._parser.register('action', 'parsers', SubParsersAction)  # NOQA
        self._program_base_initialising = True
        cls = self
        self._sub_parsers = None
        methods_with_sub_parsers = []  # list to process, multilevel
        all_methods_with_sub_parsers = []
        if self._full_package_name:
            module = import_module(
                self._full_package_name,
            )
            file_names = glob.glob(os.path.join(os.path.dirname(module.__file__),
                                                '*/__plug_in__.py'))
            for file_name in file_names:
                _, dn, fn = file_name.rsplit(os.sep, 2)
                fn = fn.replace('.py', '')
                module = import_module(
                    '.' + dn + '.' + fn,
                    package=self._full_package_name,
                )
                sp = module.load(self)  # NOQA

        def add_subparsers(method_name_list, parser, level=0):
            if not method_name_list:
                return None
            ssp = parser.add_subparsers(
                dest="subparser_level_{0}".format(level),)
            for method_name in method_name_list:
                # print('method', '  ' * level, method_name)
                method = getattr(self, method_name)
                all_methods_with_sub_parsers.append(method)
                info = method._sub_parser
                info['level'] = level
                if level > 0:
                    method._sub_parser['parent'] = \
                        method._sub_parser['kw'].pop('_parent')
                arg = method._sub_parser['args']
                if not arg or not isinstance(arg[0], string_types):
                    arg = list(arg)
                    arg.insert(0, method.__name__)
                parser = ssp.add_parser(*arg, **method._sub_parser['kw'])
                info['parser'] = parser
                res = add_subparsers(info.get('ordering', []),
                                     parser, level=level + 1)
                if res is None:
                    # only set default if there are no subparsers, otherwise
                    # defaults override
                    parser.set_defaults(func=method)
                for o in info['options']:
                    arg = list(o['args'])
                    fun_name = o.get('fun')
                    if arg:
                        # short option name only, add long option name
                        # based on function name
                        if len(arg[0]) == 2 and arg[0][0] == '-':
                            if (fun_name):
                                arg.insert(0, '--' + fun_name)
                    else:
                        # no option name
                        if o['kw'].get('nargs') == '+ ':
                            # file names etc, no leading dashes
                            arg.insert(0, fun_name)
                        else:
                            # add long option based on function name
                            arg.insert(0, '--' + fun_name)

                    try:
                        parser.add_argument(*arg, **o['kw'])
                    except ValueError:
                        print('argparse.ProgramBase arg:', repr(arg))
                        print('argparse.ProgramBase kw:', o['kw'])
                        raise
            return ssp

        def dump(method_name_list, level=0):
            if not method_name_list:
                return None
            for method_name in method_name_list:
                print('method', '  ' * level, method_name)
                method = getattr(self, method_name)
                info = method._sub_parser
                for k in sorted(info):
                    if k == 'parser':
                        v = 'ArgumentParser()'
                    elif k == 'sp':
                        v = '_SubParserAction()'
                    else:
                        v = info[k]
                    print('       ' + '  ' * level, k, '->', v)
                dump(info.get('ordering', []), level=level + 1)

        self._sub_parsers = add_subparsers(
            ProgramBase._methods_with_sub_parsers, self._parser)

        # this only does toplevel and global options
        for x in dir(self):
            if x.startswith('_') and x not in ['__init__', '_pb_init']:
                continue
            method = getattr(self, x)
            if hasattr(method, "_options"):  # not transfered to sub_parser
                for o in method._options:
                    arg = o['args']
                    kw = o['kw']
                    global_option = kw.pop('global_option', False)
                    try:
                        self._parser.add_argument(*arg, **kw)
                    except TypeError:
                        print('args, kw', arg, kw)
                    if global_option:
                        # print('global option',
                        #       arg, len(all_methods_with_sub_parsers))
                        for m in all_methods_with_sub_parsers:
                            sp = m._sub_parser['parser']
                            # adding _globa_option to allow easy check e.g. in
                            # AppConfig._set_section_defaults
                            sp.add_argument(*arg, **kw)._global_option = True
        self._program_base_initialising = False

        # print('-------------------')
        # dump(ProgramBase._methods_with_sub_parsers)
        if False:
            # for x in ProgramBase._methods_with_sub_parsers:
            for x in dir(cls):
                if x.startswith('_'):
                    continue
                method = getattr(self, x)
                if hasattr(method, "_sub_parser"):
                    if self._sub_parsers is None:
                        # create the top level subparsers
                        self._sub_parsers = self._parser.add_subparsers(
                            dest="subparser_level_0", help=None)
                    methods_with_sub_parsers.append(method)
            max_depth = 10
            level = 0
            all_methods_with_sub_parsers = methods_with_sub_parsers[:]
            while methods_with_sub_parsers:
                level += 1
                if level > max_depth:
                    raise NotImplementedError
                for method in all_methods_with_sub_parsers:
                    if method not in methods_with_sub_parsers:
                        continue
                    parent = method._sub_parser['kw'].get('_parent', None)
                    sub_parsers = self._sub_parsers
                    if parent is None:
                        method._sub_parser['level'] = 0
                        # parent sub parser
                    elif 'level' not in parent._sub_parser:
                        # print('skipping', parent.__name__, method.__name__)
                        continue
                    else:  # have a parent
                        # make sure _parent is no longer in kw
                        method._sub_parser['parent'] = \
                            method._sub_parser['kw'].pop('_parent')
                        level = parent._sub_parser['level'] + 1
                        method._sub_parser['level'] = level
                        ssp = parent._sub_parser.get('sp')
                        if ssp is None:
                            pparser = parent._sub_parser['parser']
                            ssp = pparser.add_subparsers(
                                dest="subparser_level_{0}".format(level),
                            )
                            parent._sub_parser['sp'] = ssp
                        sub_parsers = ssp
                    arg = method._sub_parser['args']
                    if not arg or not isinstance(arg[0], basestring):  # NOQA
                        arg = list(arg)
                        arg.insert(0, method.__name__)
                    sp = sub_parsers.add_parser(*arg,
                                                **method._sub_parser['kw'])
                    # add parser primarily for being able to add subparsers
                    method._sub_parser['parser'] = sp
                    # and make self._args.func callable
                    sp.set_defaults(func=method)

                    # print(x, method._sub_parser)
                    for o in method._sub_parser['options']:
                        arg = list(o['args'])
                        fun_name = o.get('fun')
                        if arg:
                            # short option name only, add long option name
                            # based on function name
                            if len(arg[0]) == 2 and arg[0][0] == '-':
                                if (fun_name):
                                    arg.insert(0, '--' + fun_name)
                        else:
                            # no option name
                            if o['kw'].get('nargs') == '+ ':
                                # file names etc, no leading dashes
                                arg.insert(0, fun_name)
                            else:
                                # add long option based on function name
                                arg.insert(0, '--' + fun_name)
                        sp.add_argument(*arg, **o['kw'])
                    methods_with_sub_parsers.remove(method)
            for x in dir(self):
                if x.startswith('_') and x not in ['__init__', '_pb_init']:
                    continue
                method = getattr(self, x)
                if hasattr(method, "_options"):  # not transfered to sub_parser
                    for o in method._options:
                        arg = o['args']
                        kw = o['kw']
                        global_option = kw.pop('global_option', False)
                        try:
                            self._parser.add_argument(*arg, **kw)
                        except TypeError:
                            print('args, kw', arg, kw)
                        if global_option:
                            # print('global option', arg,
                            #       len(all_methods_with_sub_parsers))
                            for m in all_methods_with_sub_parsers:
                                sp = m._sub_parser['parser']
                                sp.add_argument(*arg, **kw)

    def _parse_args(self, *args, **kw):
        """
        optional keyword arguments:
          default_sub_parser='<subparsername>', allows empty subparser
          help_all=True -> show help for all subcommands with --help-all
        """
        tmp_args = args if args else sys.argv[1:]
        name = kw.pop('default_sub_parser', None)
        if name is not None and '--version' not in tmp_args:
            self._parser.set_default_subparser(name, args=kw.get('args'))
        if kw.pop('help_all', None):
            if '--help-all' in tmp_args:
                try:
                    self._parser.parse_args(['--help'])
                except SystemExit:
                    pass
                for sc in self._methods_with_sub_parsers:
                    print('-' * 72)
                    try:
                        self._parser.parse_args([sc, '--help'])
                    except SystemExit:
                        pass
                sys.exit(0)
        self._args = self._parser.parse_args(*args, **kw)
        return self._args

    # def _parse_known_args(self, *args, **kw):
    #     self._args, self._unknown_args = \
    #         self._parser.parse_known_args(*args, **kw)
    #     return self._args

    @staticmethod
    def _pb_option(*args, **kw):
        def decorator(target):
            if not hasattr(target, '_options'):
                target._options = []
            # insert to reverse order of list
            target._options.insert(0, {'args': args, 'kw': kw})
            return target
        return decorator

    @staticmethod
    def _pb_sub_parser(*args, **kw):
        class Decorator(object):
            def __init__(self):
                self.target = None
                self._parent = None

            def __call__(self, target):
                self.target = target
                a = args
                k = kw.copy()
                if self._parent:
                    a = self._parent[1]
                    k = self._parent[2].copy()
                    k['_parent'] = self._parent[0]
                    pi = self._parent[0]._sub_parser
                    ordering = pi.setdefault('ordering', [])
                else:
                    ordering = ProgramBase._methods_with_sub_parsers
                ordering.append(target.__name__)
                # move options to sub_parser
                o = getattr(target, '_options', [])
                if o:
                    del target._options
                target._sub_parser = {'args': a, 'kw': k, 'options': o}
                # assign the name
                target.sub_parser = self.sub_parser
                return target

            def sub_parser(self, *a, **k):
                """ after a method xyz is decorated as sub_parser, you can add
                a sub parser by decorating another method with:
                  @xyz.sub_parser(*arguments, **keywords)
                  def force(self):
                     pass

                if arguments is not given the name will be the method name
                """
                decorator = Decorator()
                decorator._parent = (self.target, a, k, [])
                return decorator

        decorator = Decorator()
        return decorator


# decorators

def option(*args, **keywords):
    """\
 args:
    name or flags - Either a name or a list of option strings, e.g. foo or
                    -f, --foo.
 keywords:
    action   - The basic type of action to be taken when this argument is
               encountered at the command line.
    nargs    - The number of command-line arguments that should be consumed.
    const    - A constant value required by some action and nargs selections.
    default  - The value produced if the argument is absent from the command
               line.
    type     - The type to which the command-line argument should be converted.
    choices  - A container of the allowable values for the argument.
    required - Whether or not the command-line option may be omitted
               (optionals only).
    help     - A brief description of what the argument does.
    metavar  - A name for the argument in usage messages.
    dest     - The name of the attribute to be added to the object returned by
               parse_args().
    """
    return ProgramBase._pb_option(*args, **keywords)


def sub_parser(*args, **kw):
    return ProgramBase._pb_sub_parser(*args, **kw)


def version(version_string):
    return ProgramBase._pb_option(
        '--version', action='version', version=version_string)


# extra ArgumentParser functionality

def set_default_subparser(self, name, args=None):
    """default subparser selection. Call after setup, just before parse_args()
    name: is the name of the subparser to call by default
    args: if set is the argument list handed to parse_args()

    , tested with 2.7, 3.2, 3.3, 3.4
    it works with 2.6 assuming argparse is installed
    """
    subparser_found = False
    for arg in sys.argv[1:]:
        if arg in ['-h', '--help']:  # global help if no subparser
            break
    else:
        for x in self._subparsers._actions:
            if not isinstance(x, argparse._SubParsersAction):
                continue
            for sp_name in x._name_parser_map.keys():
                if sp_name in sys.argv[1:]:
                    subparser_found = True
        if not subparser_found:
            # insert default in first position, this implies no
            # global options without a sub_parsers specified
            if args is None:
                sys.argv.insert(1, name)
            else:
                args.insert(0, name)


argparse.ArgumentParser.set_default_subparser = set_default_subparser
