import socket
try:
        import simplejson as json
except ImportError:
        import json


# Helpers

def request(req):
	ret=None	
	client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
	client.connect("/tmp/bubba-apt.socket")
	client.send(json.dumps(req)+"\n")
	d=client.recv(16384);
	#print "%s"%d
	ret=json.loads(d)
	client.close()
	
	return ret

def docall(req, dump):
	ret=request(req)
	#if ret["status"]:
	if True:
		if dump:
			print json.dumps( ret, indent=4 )
		return (True,ret)
	else:
		if dump:
			print "Request failed with error '%s'"%ret["error"]
		return (False,"Request failed with error '%s'"%ret["error"])

def progress(dump=False):
	return docall({"action":"query_progress"},dump)

def upgrade(dump=False):
	return docall({"action":"upgrade_packages"},dump)

def install(package, dump=False):
	return docall({"action":"install_package","package":package},dump)

def shutdown(dump=False):
	return docall({"action":"shutdown"},dump)


if __name__=='__main__':
	query_progress(True)
	pass
