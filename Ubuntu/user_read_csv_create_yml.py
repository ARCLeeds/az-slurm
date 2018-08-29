import csv
import yaml
import sys
from pprint import pprint
import random, string, sys, getopt
from passlib.hash import sha512_crypt

DEFAULT_PASSWORD_LENGTH = 12
ALLOWED_PASSWORD_CHARS = 'abcdefghkmnoprstwxzABCDEFGHJKLMNPQRTWXY3468'
def generate_pw():
    rnd = random.SystemRandom()
    return ''.join( rnd.choice(ALLOWED_PASSWORD_CHARS) for i in range(DEFAULT_PASSWORD_LENGTH) )

csv_data = []
with open(sys.argv[1]) as csvfile:
    csvreader = csv.DictReader(csvfile)
    for row in csvreader:
        plaintext_pw = generate_pw()
        password_hash = sha512_crypt.encrypt( plaintext_pw )
        row['pass_hash'] = password_hash
        row['pass_plaintext'] = plaintext_pw
        csv_data.append(row)

pprint(csv_data)

with open('users.yml','w') as outfile:
    outfile.write(yaml.dump({'users': csv_data},default_flow_style=False))

