# Makefile integration for advanced VNDK compatibility generation

ifeq ($(TARGET_ENABLE_VNDK_COMPAT),true)

# Numeric API Levels
VNDK_VENDOR_API := $(if $(TARGET_VENDOR_API_LEVEL),$(TARGET_VENDOR_API_LEVEL),15)
VNDK_SYSTEM_API := $(if $(TARGET_SYSTEM_API_LEVEL),$(TARGET_SYSTEM_API_LEVEL),16)

VNDK_COMPAT_DIR := build/make/tools/vndk_compat/
VNDK_COMPAT_PLAN := $(PRODUCT_OUT)/vndk_compat_plan.json
VNDK_COMPAT_PROP := $(PRODUCT_OUT)/vndk_compat.prop

VNDK_SYSTEM_MODEL := $(VNDK_COMPAT_DIR)/models/v$(VNDK_SYSTEM_API).model.json
VNDK_VENDOR_FOOTPRINT := $(PRODUCT_OUT)/vendor_footprint.json
VNDK_POLICY := $(VNDK_COMPAT_DIR)/policies/v$(VNDK_VENDOR_API).policy.json

# ---------------------------------------------------------------
# Guard: Only run the pipeline if required inputs exist.
# The system model must be pre-generated (see models/README.md).
# The vendor footprint is produced during the build.
# If either is missing, print a skip message.
# ---------------------------------------------------------------
ifneq ($(wildcard $(VNDK_POLICY)),)

# 1. API Diff Engine: Analysis & Plan Generation
#    Requires: system model + vendor footprint + policy
#    If the system model doesn't exist yet, the rule will fail
#    with a clear error from make (missing prerequisite).
$(VNDK_COMPAT_PLAN): $(VNDK_COMPAT_DIR)/vndk_diff_engine.py $(VNDK_SYSTEM_MODEL) $(VNDK_VENDOR_FOOTPRINT)
	@echo "VNDK Compat Engine: Analyzing $(VNDK_VENDOR_API) -> $(VNDK_SYSTEM_API)..."
	$(hide) python3 $(VNDK_COMPAT_DIR)/vndk_diff_engine.py \
		--system-model $(VNDK_SYSTEM_MODEL) \
		--vendor-footprint $(VNDK_VENDOR_FOOTPRINT) \
		--policy $(VNDK_POLICY) \
		--output $@

# 2. Scoring System: Calculate health metrics
$(VNDK_COMPAT_PROP): $(VNDK_COMPAT_DIR)/scoring_system.py $(VNDK_COMPAT_PLAN)
	@echo "VNDK Compat: Calculating compatibility score..."
	$(hide) python3 $(VNDK_COMPAT_DIR)/scoring_system.py \
		--plan $(VNDK_COMPAT_PLAN) \
		--output-props $@

# 3. Linker IR: Transform graph to configuration
VNDK_LINKER_CONFIG := $(PRODUCT_OUT)/system/etc/linker.config.json
$(VNDK_LINKER_CONFIG): $(VNDK_COMPAT_DIR)/linker_ir.py $(VNDK_COMPAT_PLAN)
	@echo "VNDK Compat: Generating Linker Namespace via IR..."
	$(hide) python3 $(VNDK_COMPAT_DIR)/linker_ir.py \
		--input-config $(VNDK_LINKER_CONFIG).orig \
		--plan $(VNDK_COMPAT_PLAN) \
		--output $@

# Ensure properties are embedded in the system image
INTERNAL_SYSTEMIMAGE_FILES += $(VNDK_COMPAT_PROP)

else
$(warning VNDK Compat: Policy file $(VNDK_POLICY) not found. Skipping compatibility analysis.)
$(warning VNDK Compat: Create a policy at $(VNDK_POLICY) to enable the pipeline.)
endif

endif
