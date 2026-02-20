# Makefile integration for advanced VNDK compatibility generation

ifeq ($(TARGET_ENABLE_VNDK_COMPAT),true)

# Numeric API Levels
VNDK_VENDOR_API := $(if $(TARGET_VENDOR_API_LEVEL),$(TARGET_VENDOR_API_LEVEL),15)
VNDK_SYSTEM_API := $(if $(TARGET_SYSTEM_API_LEVEL),$(TARGET_SYSTEM_API_LEVEL),16)

VNDK_COMPAT_DIR := build/make/tools/vndk_compat/
VNDK_COMPAT_PLAN := $(PRODUCT_OUT)/vndk_compat_plan.json
VNDK_COMPAT_PROP := $(PRODUCT_OUT)/vndk_compat.prop

# 1. API Diff Engine: Analysis & Plan Generation
$(VNDK_COMPAT_PLAN): $(VNDK_COMPAT_DIR)/vndk_diff_engine.py
	@echo "VNDK Compat Engine: Analyzing $(VNDK_VENDOR_API) -> $(VNDK_SYSTEM_API)..."
	$(hide) python3 $< --system-model $(VNDK_COMPAT_DIR)/models/v$(VNDK_SYSTEM_API).model.json \
		--vendor-footprint $(PRODUCT_OUT)/vendor_footprint.json \
		--policy $(VNDK_COMPAT_DIR)/policies/v$(VNDK_VENDOR_API).policy.json \
		--output $@

# 2. Scoring System: Calculate health metrics
$(VNDK_COMPAT_PROP): $(VNDK_COMPAT_DIR)/scoring_system.py $(VNDK_COMPAT_PLAN)
	@echo "VNDK Compat: Calculating compatibility score..."
	$(hide) python3 $< --plan $(VNDK_COMPAT_PLAN) \
		--output-props $@

# 3. Linker IR: Transform graph to configuration
VNDK_LINKER_CONFIG := $(PRODUCT_OUT)/system/etc/linker.config.json
$(VNDK_LINKER_CONFIG): $(VNDK_COMPAT_DIR)/linker_ir.py $(VNDK_COMPAT_PLAN)
	@echo "VNDK Compat: Generating Linker Namespace via IR..."
	$(hide) python3 $< --input-config $(VNDK_LINKER_CONFIG).orig \
		--plan $(VNDK_COMPAT_PLAN) \
		--output $@

# Ensure properties are embedded in the system image
INTERNAL_SYSTEMIMAGE_FILES += $(VNDK_COMPAT_PROP)

endif
