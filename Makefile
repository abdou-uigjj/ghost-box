.PHONY: help smoke policy test fmt validate clean

help:
	@echo "ghost-box make targets"
	@echo "  smoke    - run the local no-kubernetes proof"
	@echo "  policy   - run conftest policies against k8s/"
	@echo "  test     - python unit tests"
	@echo "  fmt      - terraform fmt"
	@echo "  validate - terraform validate"
	@echo "  clean    - remove caches"

smoke:
	bash tests/local-smoke.sh

policy:
	conftest test k8s/ --policy policy/

test:
	python3 -m pytest tests/test_submission_api.py -q

fmt:
	cd terraform && terraform fmt -recursive

validate:
	cd terraform && terraform init -backend=false && terraform validate

clean:
	rm -rf .pytest_cache app/__pycache__ tests/__pycache__ terraform/.terraform
