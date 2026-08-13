# coding: utf-8
"""
The application configuration class AppConfig provides
standard location and reading of argparse defaults from
an .ini configuration file


relies on ConfigObj for reading and writing (including comments).
"""

from __future__ import print_function

# install_requires of ruamel.base is not really required but the old
# ruamel.base installed __init__.py, and thus a new version should
# be installed at some point


_package_data = dict(
    full_package_name='ruamel.appconfig',
    version_info=(0, 5, 5),
    __version__='0.5.5',
    author='Anthon van der Neut',
    author_email='a.van.der.neut@ruamel.eu',
    description='create and read configuration dir/file, set argparse (sub)parser defaults from config',  # NOQA
    entry_points=None,
    since=2014,
    install_requires=[
        # 'pon==0.2.2',
    ],
    universal=True,
    print_allowed=True,
    tox=dict(
        env='*',
        deps='pon>=0.2.2',
    ),
)  # type: Dict[Any, Any]


version_info = _package_data['version_info']
__version__ = _package_data['__version__']



import os                   # NOQA
import sys                  # NOQA
import argparse             # NOQA
if sys.version_info >= (3, 8):
    from ast import Str, Num, Bytes, NameConstant  # NOQA


try:
    import pon              # NOQA
    pon_available = True
except ImportError:
    pon_available = False

    import platform                                          # NOQA
    import datetime                                          # NOQA
    from textwrap import dedent                              # NOQA
    from _ast import *                                       # NOQA

    if sys.version_info < (3, ):
        string_type = basestring
    else:
        string_type = str

    if sys.version_info < (3, 4):
        class Bytes():  # NOQA
            pass

        class NameConstant:  # NOQA
            pass

    if sys.version_info < (2, 7) or platform.python_implementation() == 'Jython':
        class Set():
            pass

    def loads(node_or_string, dict_typ=dict, return_ast=False, file_name=None):
        """
        Safely evaluate an expression node or a string containing a Python
        expression.  The string or node provided may only consist of the following
        Python literal structures: strings, bytes, numbers, tuples, lists, dicts,
        sets, booleans, and None.
        """
        if sys.version_info < (3, 4):
            _safe_names = {'None': None, 'True': True, 'False': False}
        if isinstance(node_or_string, string_type):
            node_or_string = compile(
                node_or_string,
                '<string>' if file_name is None else file_name, 'eval', PyCF_ONLY_AST)
        if isinstance(node_or_string, Expression):
            node_or_string = node_or_string.body
        else:
            raise TypeError("only string or AST nodes supported")

        def _convert(node, expect_string=False):
            if isinstance(node, (Str, Bytes)):
                return node.s
            if expect_string:
                pass
            elif isinstance(node, Num):
                return node.n
            elif isinstance(node, Tuple):
                return tuple(map(_convert, node.elts))
            elif isinstance(node, List):
                return list(map(_convert, node.elts))
            elif isinstance(node, Set):
                return set(map(_convert, node.elts))
            elif isinstance(node, Dict):
                return dict_typ((_convert(k, expect_string=True), _convert(v)) for k, v
                                in zip(node.keys, node.values))
            elif isinstance(node, NameConstant):
                return node.value
            elif sys.version_info < (3, 4) and isinstance(node, Name):
                if node.id in _safe_names:
                    return _safe_names[node.id]
            elif isinstance(node, UnaryOp) and \
                 isinstance(node.op, (UAdd, USub)) and \
                 isinstance(node.operand, (Num, UnaryOp, BinOp)):  # NOQA
                operand = _convert(node.operand)
                if isinstance(node.op, UAdd):
                    return + operand
                else:
                    return - operand
            elif isinstance(node, BinOp) and \
                 isinstance(node.op, (Add, Sub, Mult)) and \
                 isinstance(node.right, (Num, UnaryOp, BinOp)) and \
                 isinstance(node.left, (Num, UnaryOp, BinOp)):  # NOQA
                left = _convert(node.left)
                right = _convert(node.right)
                if isinstance(node.op, Add):
                    return left + right
                elif isinstance(node.op, Mult):
                    return left * right
                else:
                    return left - right
            elif isinstance(node, Call):
                func_id = getattr(node.func, 'id', None)
                if func_id == 'dict':
                    return dict_typ((k.arg, _convert(k.value)) for k in node.keywords)
                elif func_id == 'set':
                    return set(_convert(node.args[0]))
                elif func_id == 'date':
                    return datetime.date(*[_convert(k) for k in node.args])
                elif func_id == 'datetime':
                    return datetime.datetime(*[_convert(k) for k in node.args])
                elif func_id == 'dedent':
                    return dedent(*[_convert(k) for k in node.args])
            elif isinstance(node, Name):
                return node.s
            err = SyntaxError('malformed node or string: ' + repr(node))
            err.filename = '<string>'
            err.lineno = node.lineno
            err.offset = node.col_offset
            err.text = repr(node)
            err.node = node
            raise err
        res = _convert(node_or_string)
        if not isinstance(res, dict_typ):
            raise SyntaxError("Top level must be dict not " + repr(type(res)))
        if return_ast:
            return res, node_or_string
        return res


try:
    from configobj import ConfigObj
except ImportError:
    ConfigObj = None


class AppConfig(object):
    """ToDo: update

    derives configuration filename and location from package name

    package_name is also stored to find 'local' configurations based
    on passed in directory name.
    The Config object allows for more easy change to e.g. YAML config files
    """

    if ConfigObj is not None:
        class IniConfig(ConfigObj):
            """ Config should have a __getitem__,
            preserve comments when writing
            (write config if changed)
            """
            def __init__(self, file_name, **kw):
                ConfigObj.__init__(self, file_name, *kw)

            @property
            def global_name(self):
                """old style always global"""
                return 'global'

    class YamlConfig(object):
        def __init__(self, file_name, **kw):
            import ruamel.yaml          # NOQA
            self._file_name = file_name
            try:
                self._data = ruamel.yaml.load(
                    open(file_name), ruamel.yaml.RoundTripLoader)
            except IOError:
                self._data = ruamel.yaml.comments.CommentedMap()

        def __getitem__(self, key):
            try:
                return self._data[key]
            except TypeError:
                print('data:', self._data)
                print('key: ', key)
                raise

        def __setitem__(self, key, val):
            self._data[key] = val

        def __iter__(self):
            try:
                return self._data.iterkeys()
            except AttributeError:
                return self._data.keys()

        def __len__(self):
            return len(self._data)

        def get(self, key, default=None):
            return self._data.get(key, default)

        def setdefault(self, *args, **kw):
            return self._data.setdefault(*args, **kw)

        def write(self):
            import ruamel.yaml          # NOQA
            ruamel.yaml.dump(
                self._data,
                open(self._file_name, 'w'),
                ruamel.yaml.RoundTripDumper,
                allow_unicode=True,
            )

        def __str__(self):
            return str(self._data)

        @property
        def global_name(self):
            """name of the global section"""
            if 'global' in self._data:
                return 'global'
            else:
                return 'glbl'

    class PonConfig(object):
        def __init__(self, file_name, **kw):
            self._file_name = file_name
            if pon_available:
                try:
                    self._data = pon.PON(
                        open(file_name).readlines())
                except IOError:
                    self._data = {}
            else:
                try:
                    self._data = loads(open(file_name).read(), file_name=file_name)
                except IOError:
                    self._data = {}

        def __getitem__(self, key):
            try:
                return self._data.get(key)
            except TypeError:
                print('data:', self._data)
                print('key: ', key)
                raise

        def __setitem__(self, key, val):
            self._data[key] = val

        def __iter__(self):
            try:
                return self._data.iterkeys()
            except AttributeError:
                return self._data.keys()

        def __contains__(self, key):
            return key in self._data

        def __len__(self):
            return len(self._data)

        def get(self, key, default=None):
            try:
                return self._data.get(key)
            except KeyError:
                return default

        def setdefault(self, *args, **kw):
            if isinstance(self._data, pon.PON):
                return self._data.obj.setdefault(*args, **kw)
            return self._data.setdefault(*args, **kw)

        if pon_available:
            def write(self):
                if isinstance(self._data, pon.PON):
                    self._data.dump(open(self._file_name, 'w'))
                else:
                    pon.PON(obj=self._data).dump(open(self._file_name, 'w'))

        def __str__(self):
            return str(self._data)

        @property
        def global_name(self):
            """name of the global section"""
            # only works if PON toplevel is {}, not dict()
            try:
                self._data.get('global')
                return 'global'
            except KeyError:
                return 'glbl'

    def __init__(self, package_name, **kw):
        """create a config file if no file_name given,
        complain if multiple found"""
        self._package_name = package_name
        self._file_name = None
        warning = kw.pop('warning', None)
        self._parser = parser = kw.pop('parser', None)
        # create = kw.pop('create', True)
        # if not create:
        #     return
        file_name = self.get_file_name(
            kw.pop('filename', None),
            warning=warning,
        )
        self._save_defaults = None
        if kw.pop('add_save', None):
            self.add_save_defaults(parser)
            self._save_defaults = '--save-defaults' in sys.argv
            if parser._subparsers is not None:
                assert isinstance(parser._subparsers, argparse._ArgumentGroup)
                # subparsers = {}  # aliases filtered out
                for spa in parser._subparsers._group_actions:
                    if not isinstance(spa, argparse._SubParsersAction):
                        continue
                    # print ('spa ', type(spa), spa)
                    for key in spa.choices:
                        # print ('key ', key)
                        sp = spa.choices[key]
                        # print ('sp ', type(sp), sp)
                        self.add_save_defaults(sp)
        self._config_kw = kw
        self._config = self.get_config(file_name, **self._config_kw)
        try:
            self._config_dts = os.path.getmtime(file_name)
        except OSError:
            self._config_dts = 0
        argparse._SubParsersAction.__call__ = self.sp__call__
        # super(AppConfig, self).__init__(file_name, **kw)

    def __str__(self):
        return str(self._config)

    def get_config(self, file_name, **config_kw):
        ext = file_name.rsplit('.', 1)[-1]
        if ext in ['pon']:
            return self.PonConfig(file_name, **self._config_kw)
        if ext in ['yaml', 'yml']:
            return self.YamlConfig(file_name, **self._config_kw)
        if ConfigObj is not None and ext in ['ini']:
            return self.IniConfig(file_name, **self._config_kw)

    def get_file_name(self, file_name=None, warning=None, add_save=None):
        if self._file_name:
            return self._file_name
        if warning is None:
            warning = self.no_warning
        add_config_to_parser = False
        if file_name is self.check:
            file_name = None
            if self._parser:
                add_config_to_parser = True
            # check if --config was given on commandline
            for idx, arg in enumerate(sys.argv[1:]):
                if arg.startswith('--config'):
                    if len(arg) > 8 and arg[8] == '=':
                        file_name = arg[9:]
                    else:
                        try:
                            file_name = sys.argv[idx + 2]
                        except IndexError:
                            print('--config needs an argument')
                            sys.exit(1)
        elif file_name is not None:
            # prefix filename with config dir if not absolute
            if file_name[0] != os.path.sep:
                file_name = os.path.join(AppConfig._config_dir(),
                                         self._package_name, file_name)
        expanded_file_names = [os.path.expanduser(x) for x in
                               self.possible_config_file_names]
        # print(expanded_file_names)
        existing = [x for x in expanded_file_names if os.path.exists(x)]
        # possible check for existence of preferred directory and less
        # preferred existing file
        # e.g. empty ~/.config/repo and existing ~/.repo/repo.ini
        if file_name and existing:
            warning("Multiple configuration files", [file_name] + existing)
        elif len(existing) > 1:
            warning("Multiple configuration files:", ', '.join(existing))
        if file_name:
            self._file_name = os.path.expanduser(file_name)
        elif existing:
            self._file_name = existing[0]
        else:
            self._file_name = expanded_file_names[0]
        try:
            dir_name = os.path.dirname(self._file_name)
            os.makedirs(dir_name)
            warning('created directory', dir_name, '\n')
        except OSError:
            # warning('did not create directory ', dir_name)
            pass
        if not self.has_config() and add_config_to_parser:
            if '/XXXtmp/' not in self._file_name:
                default_path = self._file_name.replace(
                    os.path.expanduser('~/'), '~/')
            else:
                default_path = self._file_name
            self._parser.add_argument(
                '--config',
                metavar='FILE',
                default=default_path,
                help="set %(metavar)s as configuration file [%(default)s]",
            )
        return self._file_name

    def file_in_config_dir(self, file_name):
        return os.path.join(os.path.dirname(self._file_name), file_name)

    def __getitem__(self, key):
        return self._config[key]

    def get(self, key, default=None):
        try:
            return self._config[key]
        except KeyError:
            return default

    def get_global(self, key=None, default=None):
        glbl = self._config[self._config.global_name]
        if glbl is None:
            return {}
        if key is None:
            return glbl
        return glbl.get(key, default)

    def set_global(self, key, value):
        self.get_global()[key] = value

    def set_defaults(self):
        # _glbl = 'global' if self._config.get('global') else 'glbl'
        _glbl = self._config.global_name
        parser = self._parser
        self._set_section_defaults(self._parser, _glbl)
        if parser._subparsers is None:
            return
        assert isinstance(parser._subparsers, argparse._ArgumentGroup)
        progs = set()
        # subparsers = {}  # aliases filtered out
        for sp in parser._subparsers._group_actions:
            if not isinstance(sp, argparse._SubParsersAction):
                continue
            for k in sp.choices:
                action = sp.choices[k]
                if self.query_add(progs, action.prog):
                    self._set_section_defaults(action, k, glbl=_glbl)
        if self._save_defaults:
            self.parse_args()

    def _set_section_defaults(self, parser, section, glbl=None):
        defaults = {}
        for action in parser._get_optional_actions():
            if isinstance(action,
                          (argparse._HelpAction,
                           argparse._VersionAction,
                           # SubParsersAction._AliasesChoicesPseudoAction,
                           )):
                continue
            for x in action.option_strings:
                if not x.startswith('--'):
                    continue
                try:
                    # get value based on long-option (without --)
                    # store in .dest
                    if self[section] is None:
                        raise KeyError
                    defaults[action.dest] = self[section][x[2:]]
                except KeyError:  # not in config file
                    if glbl is not None and \
                       getattr(action, "_global_option", False):
                        try:
                            if self[glbl] is None:
                                raise KeyError
                            defaults[action.dest] = self[glbl][x[2:]]
                        except KeyError:  # not in config file
                            pass
                break  # only first --option
        parser.set_defaults(**defaults)

    def has_config(self):
        """check if self._parser has --config already added"""
        if self._parser is not None:
            for action in self._parser._get_optional_actions():
                if '--config' in action.option_strings:
                    return True
        return False

    def parse_args(self, *args, **kw):
        """call ArgumentParser.parse_args and handle --save-defaults"""
        parser = self._parser
        opt = parser._optionals
        # print('paropt', self._parser._optionals, len(opt._actions),
        #       len(opt._group_actions))
        # for a in self._parser._optionals._group_actions:
        #     print('    ', a)
        pargs = self._parser.parse_args(*args, **kw)
        if hasattr(pargs, 'save_defaults') and pargs.save_defaults:
            self.extract_default(opt, pargs)
            # for elem in self._parser._optionals._defaults:
            #     print('elem ', elem)
            if hasattr(parser, '_sub_parser_sel'):
                name, sp = parser._sub_parser_sel
                # print('====sp', sp)
                opt = sp._optionals
                self.extract_default(opt, pargs, name)
            self._config.write()
        return pargs

    def extract_default(self, opt, pargs, name=None):
        if name is None:
            # name = 'global' if 'global' in self._config else 'glbl'
            name = self._config.global_name
        for a in opt._group_actions:
            # print('+++++', name, a)
            if isinstance(a, (argparse._HelpAction,
                              argparse._VersionAction,
                              )):
                continue
            if a.option_strings[0] in ["--config", "--save-defaults"]:
                continue
            # print('    -> ', name, a.dest, a)
            if hasattr(pargs, a.dest):
                sec = self._config.setdefault(name, {})
                sec[a.dest] = getattr(pargs, a.dest)

    @property
    def possible_config_file_names(self, ext=None):
        """return all the paths to check for configuration
        first is the one created if none found"""
        pn = self._package_name
        if ext is None:
            exts = ['.pon', '.yaml', '.yml', '.ini']
        else:
            exts = [ext]
        # ud = '~'
        ret_val = []
        for ext in exts:
            if sys.platform.startswith('win32'):
                ud = AppConfig._config_dir()
                ret_val.extend([
                    os.path.join(ud, pn, pn + ext),  # %APPDATA%/repo/repo.ext
                    os.path.join(ud, pn + ext),  # %APPDATA%/repo.ext
                ])
            else:
                ud = os.environ['HOME']
                ret_val.extend([
                    # ~/.config/repo/repo.ext
                    os.path.join(AppConfig._config_dir(), pn, pn + ext),
                    # ~/.repo/repo.ext
                    os.path.join(ud, '.' + pn, pn + ext),
                    # ~/.repo.ext
                    os.path.join(ud, '.' + pn + ext),
                ])
        return ret_val

    @staticmethod
    def add_save_defaults(p):
        p.add_argument(
            '--save-defaults',
            action='store_true',
            help='save option values as defaults to config file',
        )

    @classmethod
    def _config_dir(self):
        # https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
        attr = '_' + sys._getframe().f_code.co_name
        if not hasattr(self, attr):
            if sys.platform.startswith('win32'):
                d = os.environ['APPDATA']
            else:
                d = os.environ.get('XDG_CONFIG_HOME',
                                   os.path.join(os.environ['HOME'], '.config'))
            setattr(self, attr, d)
            return d
        return getattr(self, attr)

    @staticmethod
    def no_warning(*args, **kw):
        """sync for warnings"""
        pass

    @staticmethod
    def check():
        """to have an object to check against initing sys.argv parsing"""
        pass

    @staticmethod
    def query_add(s, value):
        """check if value in s(et) and add if not

        return True if added, False if already in.

        >>> x = set()
        >>> if query_add(x, 'a'):
        ...     print 'hello'
        hello
        >>> if query_add(x, 'a'):
        ...     print 'hello'
        >>>

        """
        if value not in s:
            s.add(value)
            return True
        return False

    @staticmethod
    def sp__call__(self, parser, namespace, values, option_string=None):
        from argparse import SUPPRESS
        parser_name = values[0]
        arg_strings = values[1:]

        # set the parser name if requested
        if self.dest is not SUPPRESS:
            setattr(namespace, self.dest, parser_name)

        # select the parser
        try:
            glob_parser = parser
            parser = self._name_parser_map[parser_name]
            glob_parser._sub_parser_sel = (parser_name, parser)
        except KeyError:
            tup = parser_name, ', '.join(self._name_parser_map)
            msg = argparse._('unknown parser %r (choices: %s)') % tup
            raise argparse.ArgumentError(self, msg)

        # parse all the remaining options into the namespace
        # store any unrecognized options on the object, so that the top
        # level parser can decide what to do with them
        namespace, arg_strings = parser.parse_known_args(
            arg_strings, namespace)
        if arg_strings:
            vars(namespace).setdefault(argparse._UNRECOGNIZED_ARGS_ATTR, [])
            getattr(namespace, argparse._UNRECOGNIZED_ARGS_ATTR).extend(arg_strings)

    def reread(self):
        """reread the config file, in case it changed on disc"""
        file_name = self.get_file_name()
        try:
            dts = os.path.getmtime(file_name)
        except OSError:
            dts = 0
        if dts > self._config_dts:
            self._config_dts = dts
            self._config = self.get_config(file_name, **self._config_kw)
            # print('rereading config ' + file_name)
            return True
        return False
