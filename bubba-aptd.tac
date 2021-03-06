#!/usr/bin/python
from apt.progress import base
from apt_pkg import gettext as _
from os import path
from twisted.internet import reactor, threads
from twisted.internet.protocol import Factory
from twisted.protocols.basic import LineReceiver
from twisted.application import service
import apt
import apt_pkg
import base64
import io
import json
import netifaces
import os
import subprocess
import syslog
import threading
import urllib
import urllib2
import re
import tempfile

SOCKNAME   = "/var/run/bubba-aptd.sock"
PIDFILE	   = '/var/run/bubba-aptd.pid'
LOGFILE	   = '/tmp/bubba-apt.log'

BUBBAKEY   = "/etc/network/bubbakey"
HOTFIX_URL = "https://hotfix.excito.org/"
UPDATE_URL = "http://b3.update.excito.org/"


class Health():
    """Handles checking the primary health of the system"""
    errors = []

    def __init__(self):
        if path.exists(LOGFILE):
            os.unlink(LOGFILE)

    def precheck(self):
        """Checks that should be done before upgrade"""
        healthy = True;
        healthy &= self._check_dpkg_status()
        healthy &= self._check_mysql_no_password()
        healthy &= self._check_functional_apache_config()
        return healthy

    def postcheck(self):
        """Checks that should be done after upgrade"""
        healthy = True;
        healthy &= self._check_dpkg_status()
        healthy &= self._check_mysql_no_password()
        healthy &= self._check_functional_apache_config()
        self._read_logfile()
        return healthy

    def get_errors(self):
        """Return the encountered errors so far"""
        retdict = {}
        for error in self.errors:
            if not error['Code'] in retdict:
                retdict[error['Code']] = []
            retdict[error['Code']].append(error)
        return retdict

    def _err(self, code, desc, data=[]):
        entry = {
            'Code': code,
            'Desc': desc,
            'Data': "\n".join(data)
        }
        self.errors.append(entry)

    def _read_logfile(self):
        """Read the log file that might have been created during the update"""
        if path.exists(LOGFILE):
            try:
                logfile = io.open(LOGFILE)
                tagfile = apt_pkg.TagFile(logfile)
                for section in tagfile:
                    data = section['Data'] if 'Data' in section else None
                    self._err(
                        code=section['Code'],
                        desc=section['Desc'],
                        data=data.split()
                    )
            except Exception:
                pass

    def haz_interwebs(self):
        """Check wherever we can connect the the Internet"""
        try:
            res = urllib2.urlopen("http://b3.update.excito.org", timeout=5)
            return True
        except urllib2.URLError:
            self._err(
                code='ERROR',
                desc=_('No functional Internet connection was found')
            )
        return False


    def _check_dpkg_status(self):
        """Check if we have broken packages currently installed/pending"""
        dpkg = subprocess.Popen(
            ['dpkg', '--list'],
            stdout=subprocess.PIPE
        )
        tail = subprocess.Popen(
            ['tail', '-n', '+6'],
            stdin=dpkg.stdout,
            stdout=subprocess.PIPE
        )
        grep = subprocess.Popen(
            ['grep', '-iE', '^.F'],
            stdin=tail.stdout,
            stdout=subprocess.PIPE
        )
        output = grep.stdout.readlines()

        if len(output):
            self._err(
                code='ERROR',
                desc=_("Failures found in package (dpkg) database, unable to "
                       "continue with upgrade"),
                data=output
            )
            return False
        return True

    def _check_mysql_no_password(self):
        """Make sure we do not have a password for mysql access"""
        import MySQLdb
        try:
            MySQLdb.connect(
                host='localhost',
                user='root'
            )
        except MySQLdb.OperationalError:
            self._err(
                code='ERROR',
                desc=_("Failed to access MySQL with default root login, "
                       "unable to continue with upgrade")
            )
            return False
        return True

    def _check_functional_apache_config(self):
        """Make sure that apache can be restarted"""
        from subprocess import Popen, PIPE
        p = Popen(
            ['/usr/sbin/apache2ctl', 'configtest'],
            stderr=PIPE,
            stdout=PIPE
        )
        stdout, stderr = p.communicate()
        if p.returncode != 0:
            self._err(
                code='ERROR',
                desc=_('Webserver (apache2) config contains syntax errors'),
                data=stderr.rstrip()
            )
            return False
        return True

class BubbaProgress(object):

    def __init__(self, status):
        self._status = status;

    def set_status(self, status=None, percent=None, error=False):
        """Set the current status for the progress,
        as we are only interested in the latest status message, we keep it simple
        in a dict."""

        if 'error' in self._status and self._status['error'] and not error:
            """Do not update the status if we have already have an error"""
            return

        if status:
            self._status['status'] = status

        if percent and percent != -1:
            self._status['percent'] = percent

        if error:
            self._status['error'] = True

class BubbaOpProgress(base.OpProgress, BubbaProgress):
    def __init__(self, status):
        BubbaProgress.__init__(self, status)
        base.OpProgress.__init__(self)

    def update(self, percent=None):
        """Called periodically to update the user interface."""
        base.OpProgress.update(self, self.percent)
        self.set_status(percent=self.percent, status=self.op)

    def done(self):
        """Called once an operation has been completed."""
        base.OpProgress.done(self)
        self.set_status(percent=100, status=self.op)

class BubbaInstallProgress(base.InstallProgress, BubbaProgress):
    def __init__(self, status):
        BubbaProgress.__init__(self, status)
        base.InstallProgress.__init__(self)

    def error(self, pkg, errormsg):
        """Called if dpkg signalled error"""
        self.set_status(
            error=True,
            status=_("Error in package %(package)s: %(errormsg)s") % {
                'package': pkg,
                'errormsg': errormsg
            }
        )

    def start_update(self):
        """Called at start of upgrade"""
        self.set_status(percent=0, status=_("Starting..."))

    def finish_update(self):
        """Called when upgrade is done"""
        self.set_status(percent=100, status=_("Complete"))

    def processing(self, pkg, stage):
        """Called when processing a package"""
        self.set_status(percent= -1, status=_("Installing %s...") % pkg)

    def status_change(self, pkg, percent, status):
        """Called when status has changed"""
        self.set_status(percent=percent, status=status)

class BubbaAcquireProgress(base.AcquireProgress, BubbaProgress):
    def __init__(self, status):
        BubbaProgress.__init__(self, status)
        base.AcquireProgress.__init__(self)

    def start(self):
        """Called when starting acquiring packages"""
        base.AcquireProgress.start(self)
        self.set_status(percent=0, status=_("Starting..."))

    def stop(self):
        """Called when we are done fetching"""
        base.AcquireProgress.stop(self)
        self.set_status(percent=100, status=_("Complete"))

    def pulse(self, owner):
        """Called now and then during fetching"""
        base.AcquireProgress.pulse(self, owner)
        current_item = self.current_items + 1
        if current_item > self.total_items:
            current_item = self.total_items

        if self.current_cps > 0:
            text = (_("Downloading file %(current)li of %(total)li with "
                      "%(speed)s/s") % \
                    {"current": current_item,
                     "total": self.total_items,
                     "speed": apt_pkg.size_to_str(self.current_cps)})
        else:
            text = (_("Downloading file %(current)li of %(total)li") % \
                    {"current": current_item,
                     "total": self.total_items})

        percent = (((self.current_bytes + self.current_items) * 100.0) /
                   float(self.total_bytes + self.total_items))
        self.set_status(percent=percent, status=text)
        return True


def dist_upgrade(status):
    """
    Execute an full distribution upgrade of the system,
    though we will only upgrade packages from out own repositories,
    excluding any packages directly installed from debian proper.
    """

    health = Health()
    if not health.haz_interwebs():
        status['done'] = True
        status['percent'] = 100;
        status['logs'] = health.get_errors()
        return

    try:
        run_hotfix(status)
    except HotfixException, e:
        # hotfix system indicate we should stop
        status['done'] = True
        status['percent'] = 100;
        status['logs'] = {}
        status['logs'][e.code] = [{
            'Code': e.code,
            'Desc': e.value,
            'Data': ""
        }]
        return


    status['action'] = _('Step 1: Verifying pre upgrade system integrity')

    if health.precheck():
        status['action'] = _("Step 2: Initiating distribution upgrade")
        op_progress = BubbaOpProgress(status)
        aquire_progress = BubbaAcquireProgress(status)
        install_progress = BubbaInstallProgress(status)

        cache = apt.Cache(op_progress)
        status['action'] = _("Step 2: Update available sources")
        cache.update(
            fetch_progress=aquire_progress
        )

        cache.open(op_progress)
        cache._depcache.policy.read_pinfile("/etc/apt/preferences.d/excito")
        cache._depcache.init(op_progress)

        cache.upgrade(True)

        nbr_install = cache.install_count

        if nbr_install == 0:
            status['action'] = _('Upgrade halted')
            status['status'] = _('Nothing to upgrade')
        else:
            status['action'] = _("Step 3: Upgrading")

            try:
                cache.commit(
                    aquire_progress,
                    install_progress
                )
            except SystemError as err:
                pass

            status['action'] = _('Step 4: Verifying post upgrade system integrity')
            if health.postcheck():
                status['action'] = _("Upgrade complete")
                status['status'] = _("%(count)d packages upgraded") % {
                    'count': nbr_install
                }
            else:
                status['status'] = _("Post upgrade system integrity violated")
                status['logs'] = health.get_errors()

    else:
        status['status'] = _("Pre upgrade system integrity violated")
        status['logs'] = health.get_errors()

    status['done'] = True
    status['logs'] = health.get_errors()

    return True


def install_package(package, status):
    """Install a single package from our repository"""
    status['action'] = _("Initiating installation")
    cache = apt.Cache(BubbaOpProgress(status))
    status['action'] = _("Update available sources")

    cache.update(
        fetch_progress=BubbaAcquireProgress(status)
    )

    cache.update(BubbaAcquireProgress(status))
    cache.open(BubbaOpProgress(status))

    if package in cache:
        pkg = cache[package]
        pkg.mark_install()
    else:
        status['status'] = _("Requested package %s was not found") % package
        status['done'] = True
        return

    status['action'] = _("Installing")
    cache.commit(
        BubbaAcquireProgress(status),
        BubbaInstallProgress(status)
    )
    status['done'] = True
    return

class HotfixStatus():
    FOUND = 0x0001 # Hotfix was found
    BLOCK = 0x0002 # Upgrade must be blocked
    SCRIPTS = 0x0004 # hotfix includes executeable scripts
    FILES = 0x0008 # hotfix includes files to be installed
    # Error states
    MAC_KEY_MISSMATCH = 0x4000 # mac id and key not matched
    FAILED_REQUEST = 0x8000 # request has failed

class HotfixException(Exception):

    def __init__(self, code, value):
        self.code = code
        self.value = value

    def __str__(self):
        return "%(type)s: %(value)s" % {
            'type': self.type,
            'value': self.value
        }

def run_hotfix(status):
    status['action'] = _('Hotfix')
    status['status'] = _('Gathering data for remote analysis')
    args = {}

    # Current LAN interface
    LAN = subprocess.Popen(
        ['bubba-networkmanager-cli', 'getlanif'],
        stdout=subprocess.PIPE
    ).communicate()[0].strip()

    # current WAN interface
    WAN = subprocess.Popen(
        ['bubba-networkmanager-cli', 'getwanif'],
        stdout=subprocess.PIPE
    ).communicate()[0].strip()

    # Retrieve mac and ip for WAN
    try:
        interface = netifaces.ifaddresses(WAN)
        if netifaces.AF_LINK in interface:
            args['mac_1'] = interface[netifaces.AF_LINK][0]['addr']
        if netifaces.AF_INET in interface:
            args['ip_1'] = interface[netifaces.AF_INET][0]['addr']
    except ValueError as e:
        pass

    # Retrieve mac and ip for LAN
    try:
        interface = netifaces.ifaddresses(LAN)
        if netifaces.AF_LINK in interface:
            args['mac_2'] = interface[netifaces.AF_LINK][0]['addr']
        if netifaces.AF_INET in interface:
            args['ip_2'] = interface[netifaces.AF_INET][0]['addr']
    except ValueError as e:
        pass

    # Total amount of memory
    try:
        meminfo = dict(re.findall(r'(.*?)\s*:\s*(.*)\s*', open('/proc/meminfo', 'r').read()))
    except Exception as e:
        pass
    if 'MemTotal' in meminfo:
        args['ram'] = meminfo['MemTotal']

    # Hardwaer model
    cpuinfo = dict(re.findall(r'(.*?)\s*:\s*(.*)\s*', open('/proc/cpuinfo', 'r').read()))
    if 'model' in cpuinfo:
        args['cpu'] = cpuinfo['model']

    # Our secret key
    cmdline = dict(re.findall(r'(\w+)=(\S+)\s', open('/proc/cmdline', 'r').read()))
    if 'key' in cmdline and cmdline['key'] != '':
        args['secret_key'] = cmdline['key']
    else:
        args['secret_key'] = 'zuwnerrb'

    # Our serial number
    if 'serial' in cmdline:
        args['serial'] = cmdline['serial']

    # Get list of our packages
    dpkg = subprocess.Popen(
        ['dpkg-query', '--show', '--showformat', '${Status}\t${Package}\t${Version}\n', 'bubba-*', 'logitechmediaserver', 'filetransferdaemon'],
        stdout=subprocess.PIPE
    )

    args['dpkg'] = map(lambda x: x.strip().split('\t') , dpkg.stdout.readlines())

    # previous bubba-apt log
    if os.path.exists('/tmp/bubba-apt.log'):
        args['bubba_apt_log'] = open('/tmp/bubba-apt.log', 'r').read().strip()

    # last time we had a run
    if os.path.exists('/var/lib/bubba/hotfix.date'):
        args['last_date'] = open('/var/lib/bubba/hotfix.date', 'r').read().strip()

    # current system version
    if os.path.exists('/etc/bubba.version'):
        args['version'] = open('/etc/bubba.version', 'r').read().strip()

    # current running kernel
    args['kernel'] = subprocess.Popen(
        ['uname', '-r'],
        stdout=subprocess.PIPE
    ).communicate()[0].strip()

    # Home partition mode
    disks = json.loads(
        subprocess.Popen(
            ['diskmanager', 'disk', 'list'],
            stdout=subprocess.PIPE
        ).communicate()[0].strip()
    )

    for disk in disks:
        if not('dev' in disk and disk['dev'] == '/dev/sda'):
            continue
        args['hd_model'] = disk['model']
        if not 'partitions' in disk:
            break
        for part in disk['partitions']:
            if not ('dev' in part and part['dev'] == '/dev/sda2'):
                continue
            args['hd_usage'] = part['usage']
            break
        break

    # root partition free space
    disk = os.statvfs('/')
    free_space = int(disk.f_bsize * disk.f_bavail / 1024)
    args['root_avail'] = free_space

    try:
        status['status'] = _('Requesting directives from remote hotfix server')
        res = urllib2.urlopen(HOTFIX_URL, urllib.urlencode({'data': json.dumps(args)}))
        data = res.read()
        import gnupg

        gpg = gnupg.GPG(keyring="/usr/share/keyrings/excito-hotfix-keyring.gpg")
        verified = gpg.verify(data)

        if not verified:
            raise HotfixException('ERROR', 'Was unable to verify the authenticity of the returned data. Aborting upgrade; please contact support')

        decrypted = gpg.decrypt(data)
        raw_data = decrypted.data

        data = json.loads(raw_data)
        if 'status' in data:
            stat = data['status']
            if stat & HotfixStatus.FOUND:
                if stat & HotfixStatus.FILES:
                    status['status'] = _('Installing requested files')
                    for _file in data['files']:
                        syslog.syslog(
                            "Installing %(filename)s to %(destination)s" % _file
                        )
                        status['status'] = _("Installing %(filename)s") % _file
                        mod = int(_file['mod']) if 'mod' in _file else 0644
                        uid = int(_file['uid']) if 'uid' in _file else 1
                        gid = int(_file['gid']) if 'gid' in _file else 1
                        with open(_file['destination'], 'wb') as fh:
                            fh.write(base64.b64decode(_file['data']))
                            os.fchmod(fh.fileno(), mod)
                            os.fchown(fh.fileno(), uid, gid)

                if stat & HotfixStatus.SCRIPTS:
                    status['status'] = _('Applying requested scripts')
                    for _script in data['scripts']:
                        syslog.syslog(
                            "Applying %(scriptname)s" % _script
                        )
                        status['status'] = _("Applying %(scriptname)s") % _script
                        try:
                            fd, name = tempfile.mkstemp()
                            os.write(fd,base64.b64decode(_script['data']))
                            os.fchmod(fd, 0700)
                            os.close(fd)
                            subprocess.call([name], shell=True)
                        except Exception as err:
                            syslog.syslog(syslog.LOG_ERR, str(err))
                            raise HotfixException('ERROR', _('Fatal error executing hotfix, aborting upgrade; Please contact support'))
                        finally:
                            if path.exists(name):
                                os.unlink(name)


                if stat & HotfixStatus.BLOCK:
                    raise HotfixException('WARN', _('More updates may be available - please run the update again.'))
                else:
                    status['status'] = _('Hotfixes applied, proceeding with upgrade.')
            elif stat & HotfixStatus.BLOCK:
                raise HotfixException('WARN', _('Automatic updates has been blocked by serverside.'))
            elif stat & HotfixStatus.FAILED_REQUEST:
                if stat & HotfixStatus.MAC_KEY_MISSMATCH:
                    raise HotfixException('ERROR', _("MAC address and system key does not match, "
                                                    "or is not registered; please contact support"))
                else:
                    raise HotfixException('ERROR', _("Server indicated failure, but did not specify reason. "
                                                    "Aborting upgrade; Please contact support"))
            else:
                status['status'] = _("No hotfixes available, proceeding with upgrade.")
        else:
            raise HotfixException('ERROR', _("Failed to verify response from server, aborting upgrade"))
        return

    except HotfixException:
        raise
    except urllib2.URLError as e:
        syslog.syslog(syslog.LOG_ERR, "Unable to download data:  " + str(e))
        raise HotfixException('ERROR', _('Was unable to connect to the update server. Aborting upgrade. Please check internet connection.'))
    except Exception, e:
        syslog.syslog("unknown exception: " + str(e))
        raise HotfixException('ERROR', _('Unknown error occured while trying to apply hotfixes; aborting upgrade; please contact support'))

class BubbaAptError(Exception):

    def __init__(self, value):
        self.value = value

    def __str__(self):
        return str(self.value)


systemLock = threading.Lock()

class AptProtocol(LineReceiver):

    def _do_err(self, err):
        syslog.syslog("Errback got: " + str(err))

    def _reset(self, x):
        """we'll reset the status after 6 seconds after conclusion of an upgrade/install"""
        def __do_reset():
            systemLock.release()
            self.factory._status.clear()
            syslog.syslog("Resetting daemon")
        reactor.callLater(6, __do_reset)

    def lineReceived(self, line):
        try:
            decoded = json.loads(line)
            if "action" in decoded:
                action = decoded['action']

                if action == "install_package":

                    if not 'package' in decoded:
                        raise BubbaAptError("Missing parameter 'package'")

                    if systemLock.acquire(False):
                        package = decoded['package']
                        d = threads.deferToThread(
                            install_package,
                            package,
                            self.factory._status
                        )
                        d.addCallback(self._reset)
                        d.addErrback(self._do_err)
                        self.sendLine(json.dumps({"response": "install_package"}))
                    else:
                        raise BubbaAptError("Server is busy working")

                elif action == "upgrade_packages":

                    if systemLock.acquire(False):
                        d = threads.deferToThread(
                            dist_upgrade,
                            self.factory._status
                        )
                        d.addCallback(self._reset)
                        d.addErrback(self._do_err)
                        self.sendLine(json.dumps({"response": "upgrade_packages"}))
                    else:
                        raise BubbaAptError("Server is busy working")

                elif action == "query_progress":

                    retval = {
                        'progress': 0,
                        'fixedMessage': "",
                        'statusMessage': "",
                        'done': False,
                        'logs': "",
                    }
                    if 'action' in self.factory._status:
                        retval['fixedMessage'] = self.factory._status['action']

                    if 'status' in self.factory._status:
                        if 'action' in self.factory._status:
                            retval['statusMessage'] = "%(action)s: %(status)s" % {
                                'action': self.factory._status['action'],
                                'status': self.factory._status['status']
                            }
                        else:
                            retval['statusMessage'] = self.factory._status['status']

                    if 'percent' in self.factory._status:
                        retval['progress'] = self.factory._status['percent']

                    if 'logs' in self.factory._status:
                        retval['logs'] = self.factory._status['logs']

                    if 'done' in self.factory._status and self.factory._status['done']:
                        retval['done'] = True

                    self.sendLine(json.dumps(retval))

                else:
                    self.sendLine(json.dumps({"response": "unknown_action"}))

            else:
                self.sendLine(json.dumps({"response": "unknown_command"}))

        except ValueError:
            self.sendLine(json.dumps({"response": "error_decoding"}))
        except BubbaAptError as error:
            self.sendLine(json.dumps({"response": "error", "message": str(error)}))
        except Exception as e:
            syslog.syslog("Got excpection: " + str(e))

        self.transport.loseConnection()

class AptFactory(Factory):

    _status = None
    protocol = AptProtocol

    def __init__(self, status):
        self._status = status


def program_cleanup(self, arg):
    """Called when terminating the daemon"""
    syslog.syslog("Caught SIGTERM")
    reactor.fireSystemEvent('shutdown')
    reactor.stop()

class AptService (service.Service):

    def __init__(self):
        pass

    def startService(self):
        global status, hotfix_status
        syslog.openlog("bubba-aptd", syslog.LOG_PID, syslog.LOG_DAEMON)

        status = {}
        hotfix_status = {}

        os.environ['DEBIAN_FRONTEND'] = 'noninteractive'
        os.environ['APT_LISTCHANGES_FRONTEND'] = 'none'

        if os.path.exists("/etc/apt/bubba-apt.conf"):
            apt_pkg.read_config_file(apt_pkg.config, "/etc/apt/bubba-apt.conf")

        if os.path.exists(SOCKNAME):
            os.unlink(SOCKNAME)

        # mode is restricted to root, as we dont' want anyone to be able to initiate an upgrade
        reactor.listenUNIX(SOCKNAME, AptFactory(status), mode=0600)

    def stopService(self):
        pass


application = service.Application("Excito Apt Service")
aptService = AptService()
aptService.setServiceParent(application)

if __name__ == "__main__":
    pass
