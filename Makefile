
.PHONY = run clean-logs


run: clean-logs
	perl poll.pl --poll=45 --verbose --repo `echo ~/Code/github/* | sed -ne 's/ / --repo=/gp'`

clean-logs:
	rm /tmp/*.log || true
	rm /tmp/updater/*.log || true
	rm /tmp/data_* || true

