#! /usr/bin/python
# coding: utf-8


#
# This is a simple script to create a remote directory over ssh
#
# Invoked as sshmkdir.py /path/to/jobcfgfile
#
# It then reads this file and uses target_* to get info on what
# to do
#
# upon completion it outputs 
#	Error: "errmsg" upon failure
#       Success created: path_created upon success 
#

import pexpect
import sys

if len(sys.argv) != 2:
	print "Usage: sshmkdir path_to_jobfile"
	print "Error: wrong amt of arguments."
	sys.exit(1)

cfgfile=file(sys.argv[1])
cfg={}
for line in cfgfile:
	if line.startswith(';') or line.startswith('#') or line=='': pass
	
	key=line[ : line.find('=') ].strip()
	val=line[ line.find('=') + 1 : ].strip()

	cfg[key]=val


password = cfg["target_FTPpasswd"]
user = cfg["target_user"]
host = cfg["target_host"]
path = cfg["target_path"]

cmd = 'mkdir -p'
rcmd = cmd+' '+'"'+path+'"'
ssh = '/usr/bin/ssh'

#log=sys.stdout
log=None

#out=sys.stdout
out=None

err='None'

p=pexpect.spawn( ssh+" "+user+"@"+host+" "+rcmd,logfile=log)

def logg(p):
	global err
	err=p
	if(out!=None):
		out.write(p+"\n")

while 1:
	i=p.expect( [
		pexpect.EOF,
		pexpect.TIMEOUT,
		"(?i)timeout, server not responding",
		"(?i)connection timed out",
		"(?i)pass(word|phrase .*):",
		"(?i)permission denied",
		"(?i)authentication failure",
		"(?i)mkdir: cannot create directory",
		"(?i)Are you sure you want to continue connecting .*\?",
		"(?i)Could not resolve hostname",
		"(?i)command not found",
		"exnomatch"])
	
	if i==0:
		logg("Commmand terminated")
		break
	elif i==1:
		logg("Command timeout")
		break
	elif i==2 or i==3:
		logg("Connection timeout")
	elif i==4:
		logg("Sending password")
		p.sendline(password)
	elif i==5:
		log("Permission denied")
		break
	elif i==6:
		logg("Authentication failed")
		break
	elif i==7:
		logg("Failed to create dir")
		break
	elif i==8:
		logg("Sending yes accept new host")
		p.sendline('yes')
	elif i==9:
		logg("Failed to lookup host")
		break
	elif i==10:
		logg("Unknown command")
		break

p.close()

exstaus=None

if(p.signalstatus==None):
	exstatus=p.exitstatus
else:
	exstatus=p.signalstatus

if exstatus!=0:
	print "Error: "+err
else:
	print "Success created: "+user+"@"+host+path
