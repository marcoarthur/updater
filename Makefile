
.PHONY = run clean-logs

UPDIR = ~/Code/github
POLL = 20

run: clean-logs
	perl poll.pl --poll=$(POLL) --verbose --repo `echo $(UPDIR)/* | sed -ne 's/ / --repo=/gp'`

clean-logs:
	rm /tmp/*.log || true
	rm /tmp/updater/*.log || true
	rm /tmp/data_* || true

