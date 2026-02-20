# Makefile integration for future-proof VNDK compatibility generation

ifeq ($(TARGET_ENABLE_VNDK_COMPAT),true)

# Use TARGET_VENDOR_API_LEVEL and TARGET_SYSTEM_API_LEVEL from environment or board config
VNDK_VENDOR_API := $(if $(TARGET_VENDOR_API_LEVEL),$(TARGET_VENDOR_API_LEVEL),15)
VNDK_SYSTEM_API := $(if $(TARGET_SYSTEM_API_LEVEL),$(TARGET_SYSTEM_API_LEVEL),16)

VNDK_COMPAT_TOOLS := build/make/tools/vndk_compat/
VNDK_COMPAT_PLAN := $(PRODUCT_OUT)/vndk_compat_plan.json

# 1. Generate the compatibility plan using the version-agnostic engine
$(VNDK_COMPAT_PLAN): $(VNDK_COMPAT_TOOLS)/vndk_compat_engine.py
	@echo "VNDK Compat Engine: Analyzing API level $(VNDK_VENDOR_API) -> $(VNDK_SYSTEM_API)..."
	$(hide) python3 $< --vendor-api $(VNDK_VENDOR_API) \
		--system-api $(VNDK_SYSTEM_API) \
		--vendor-dir $(TARGET_VENDOR_PATH) \
		--system-dir $(PRODUCT_OUT)/system \
		--policy-dir $(VNDK_COMPAT_TOOLS)/policies \
		--output $@

# 2. Patch the linker configuration using the AST tool
VNDK_LINKER_CONFIG := $(PRODUCT_OUT)/system/etc/linker.config.json
$(VNDK_LINKER_CONFIG): $(VNDK_COMPAT_TOOLS)/linker_config_ast.py $(VNDK_COMPAT_PLAN)
	@echo "VNDK Compat: Patching linker configuration via AST..."
	$(hide) python3 $< --input $(VNDK_LINKER_CONFIG).orig \
		--policy $(VNDK_COMPAT_TOOLS)/policies/v$(VNDK_VENDOR_API).policy.json \
		--output $@

INTERNAL_SYSTEMIMAGE_FILES += $(VNDK_COMPAT_PLAN)

endif
