// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import { IAccessController } from "contracts/interfaces/IAccessController.sol";
import { ILicensingModule } from "contracts/interfaces/modules/licensing/ILicensingModule.sol";
import { IRoyaltyModule } from "contracts/interfaces/modules/royalty/IRoyaltyModule.sol";
import { Errors } from "contracts/lib/Errors.sol";
import { UMLPolicyFrameworkManager } from "contracts/modules/licensing/UMLPolicyFrameworkManager.sol";

import { BaseTest } from "test/foundry/utils/BaseTest.t.sol";

contract UMLPolicyFrameworkCompatibilityTest is BaseTest {
    UMLPolicyFrameworkManager internal umlFramework;

    string internal licenseUrl = "https://example.com/license";
    address internal ipId1;
    address internal ipId2;

    modifier withUMLPolicySimple(
        string memory name,
        bool commercial,
        bool derivatives,
        bool reciprocal
    ) {
        _mapUMLPolicySimple(name, commercial, derivatives, reciprocal, 100, 100);
        _addUMLPolicyFromMapping(name, address(umlFramework));
        _;
    }

    modifier withAliceOwningDerivativeIp2(string memory policyName) {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId1, 100);

        // Must add the policy first to set the royalty policy (if policy is commercial)
        // Otherwise, minting license will fail because there's no royalty policy set for license policy,
        // AND bob (the caller) is not the owner of IPAccount 1.
        vm.startPrank(bob);
        uint256 licenseId = licensingModule.mintLicense(_getUmlPolicyId(policyName), ipId1, 1, alice);

        vm.startPrank(alice);
        uint256[] memory licenseIds = new uint256[](1);
        licenseIds[0] = licenseId;
        licensingModule.linkIpToParents(licenseIds, ipId2, 0);
        vm.stopPrank();
        _;
    }

    function setUp() public override {
        super.setUp();
        buildDeployRegistryCondition(DeployRegistryCondition({ licenseRegistry: true, moduleRegistry: false }));
        buildDeployModuleCondition(
            DeployModuleCondition({
                registrationModule: false,
                disputeModule: false,
                royaltyModule: false,
                taggingModule: false,
                licensingModule: true
            })
        );
        deployConditionally();
        postDeploymentSetup();

        // Call `getXXX` here to either deploy mock or use real contracted deploy via the
        // deployConditionally() call above.
        // TODO: three options, auto/mock/real in deploy condition, so no need to call getXXX
        accessController = IAccessController(getAccessController());
        licensingModule = ILicensingModule(getLicensingModule());
        royaltyModule = IRoyaltyModule(getRoyaltyModule());

        umlFramework = new UMLPolicyFrameworkManager(
            address(accessController),
            address(ipAccountRegistry),
            address(licensingModule),
            "UMLPolicyFrameworkManager",
            licenseUrl
        );

        licensingModule.registerPolicyFrameworkManager(address(umlFramework));

        mockNFT.mintId(bob, 1);
        mockNFT.mintId(alice, 2);
        ipId1 = ipAccountRegistry.registerIpAccount(block.chainid, address(mockNFT), 1);
        ipId2 = ipAccountRegistry.registerIpAccount(block.chainid, address(mockNFT), 2);
        vm.label(ipId1, "IP1");
        vm.label(ipId2, "IP2");

        vm.label(LIQUID_SPLIT_FACTORY, "LIQUID_SPLIT_FACTORY");
        vm.label(LIQUID_SPLIT_MAIN, "LIQUID_SPLIT_MAIN");
    }

    /////////////////////////////////////////////////////////////
    //////  SETTING POLICIES IN ORIGINAL WORK (NO PARENTS) //////
    /////////////////////////////////////////////////////////////

    function test_UMLPolicyFramework_originalWork_bobAddsDifferentPoliciesAndAliceMints()
        public
        withUMLPolicySimple("comm_deriv", true, true, false)
        withUMLPolicySimple("comm_non_deriv", true, false, false)
    {
        // Bob can add different policies on IP1 without compatibility checks.
        vm.startPrank(bob);
        licensingModule.addPolicyToIp(ipId1, _getUmlPolicyId("comm_deriv"));
        licensingModule.addPolicyToIp(ipId1, _getUmlPolicyId("comm_non_deriv"));
        vm.stopPrank();

        bool isInherited = false;
        assertEq(licensingModule.totalPoliciesForIp(isInherited, ipId1), 2);
        assertTrue(
            licensingModule.isPolicyIdSetForIp(isInherited, ipId1, _getUmlPolicyId("comm_deriv")),
            "comm_deriv not set"
        );
        assertTrue(
            licensingModule.isPolicyIdSetForIp(isInherited, ipId1, _getUmlPolicyId("comm_non_deriv")),
            "comm_non_deriv not set"
        );

        mockRoyaltyPolicyLS.setMinRoyalty(ipId1, 100);

        // Others can mint licenses to make derivatives of IP1 from each different policy,
        // as long as they pass the verifications
        uint256 licenseId1 = licensingModule.mintLicense(_getUmlPolicyId("comm_deriv"), ipId1, 1, dan);
        assertEq(licenseRegistry.balanceOf(dan, licenseId1), 1, "Don doesn't have license1");

        uint256 licenseId2 = licensingModule.mintLicense(_getUmlPolicyId("comm_non_deriv"), ipId1, 1, dan);
        assertEq(licenseRegistry.balanceOf(dan, licenseId2), 1, "Don doesn't have license2");
    }

    function test_UMLPolicyFramework_originalWork_bobMintsWithDifferentPolicies()
        public
        withUMLPolicySimple("comm_deriv", true, true, false)
        withUMLPolicySimple("comm_non_deriv", true, false, false)
    {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId1, 100);

        // Bob can add different policies on IP1 without compatibility checks.
        vm.startPrank(bob);
        uint256 licenseId1 = licensingModule.mintLicense(_getUmlPolicyId("comm_deriv"), ipId1, 2, dan);
        assertEq(licenseRegistry.balanceOf(dan, licenseId1), 2, "Don doesn't have license1");

        uint256 licenseId2 = licensingModule.mintLicense(_getUmlPolicyId("comm_non_deriv"), ipId1, 1, dan);
        assertEq(licenseRegistry.balanceOf(dan, licenseId2), 1, "Don doesn't have license2");
        vm.stopPrank();
    }

    function test_UMLPolicyFramework_originalWork_bobSetsPoliciesThenCompatibleParent()
        public
        withUMLPolicySimple("comm_deriv", true, true, false)
        withUMLPolicySimple("comm_non_deriv", true, false, false)
    {
        // TODO: This works if all policies compatible.
        // Can bob disable some policies?
    }

    /////////////////////////////////////////////////////////////////
    //////  SETTING POLICIES IN DERIVATIVE WORK (WITH PARENTS) //////
    /////////////////////////////////////////////////////////////////

    function test_UMLPolicyFramework_derivative_revert_cantMintDerivativeOfDerivative()
        public
        withUMLPolicySimple("comm_non_deriv", true, false, false)
        withAliceOwningDerivativeIp2("comm_non_deriv")
    {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId2, 100);

        vm.expectRevert(Errors.LicensingModule__MintLicenseParamFailed.selector);
        vm.startPrank(dan);
        licensingModule.mintLicense(_getUmlPolicyId("comm_non_deriv"), ipId2, 1, dan);

        vm.expectRevert(Errors.LicensingModule__MintLicenseParamFailed.selector);
        vm.startPrank(alice);
        licensingModule.mintLicense(_getUmlPolicyId("comm_non_deriv"), ipId2, 1, alice);
    }

    function test_UMLPolicyFramework_derivative_revert_AliceCantSetPolicyOnDerivativeOfDerivative()
        public
        withUMLPolicySimple("comm_non_deriv", true, false, false)
        withUMLPolicySimple("comm_deriv", true, true, false)
        withAliceOwningDerivativeIp2("comm_non_deriv")
    {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId2, 100);

        vm.expectRevert(Errors.LicensingModule__DerivativesCannotAddPolicy.selector);
        vm.prank(alice);
        licensingModule.addPolicyToIp(ipId2, _getUmlPolicyId("comm_deriv"));

        _mapUMLPolicySimple("other_policy", true, true, false, 100, 100);
        _getMappedUmlPolicy("other_policy").attribution = false;
        _addUMLPolicyFromMapping("other_policy", address(umlFramework));

        vm.expectRevert(Errors.LicensingModule__DerivativesCannotAddPolicy.selector);
        vm.prank(alice);
        licensingModule.addPolicyToIp(ipId2, _getUmlPolicyId("other_policy"));
    }

    /////////////////////////////////////////////////////////////////
    //////                RECIPROCAL DERIVATIVES               //////
    /////////////////////////////////////////////////////////////////

    function test_UMLPolicyFramework_reciprocal_DonMintsLicenseFromIp2()
        public
        withUMLPolicySimple("comm_reciprocal", true, true, true)
        withAliceOwningDerivativeIp2("comm_reciprocal")
    {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId2, 100);

        vm.prank(dan);
        uint256 licenseId = licensingModule.mintLicense(_getUmlPolicyId("comm_reciprocal"), ipId2, 1, dan);
        assertEq(licenseRegistry.balanceOf(dan, licenseId), 1, "Don doesn't have license");
    }

    function test_UMLPolicyFramework_reciprocal_AliceMintsLicenseForP1inIP2()
        public
        withUMLPolicySimple("comm_reciprocal", true, true, true)
        withAliceOwningDerivativeIp2("comm_reciprocal")
    {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId2, 100);

        vm.prank(alice);
        uint256 licenseId = licensingModule.mintLicense(_getUmlPolicyId("comm_reciprocal"), ipId2, 1, alice);
        assertEq(licenseRegistry.balanceOf(alice, licenseId), 1, "Alice doesn't have license");
    }

    function test_UMLPolicyFramework_reciprocal_revert_AliceTriesToSetPolicyInReciprocalDeriv()
        public
        withUMLPolicySimple("comm_reciprocal", true, true, true)
        withUMLPolicySimple("other_policy", true, true, false)
        withAliceOwningDerivativeIp2("comm_reciprocal")
    {
        mockRoyaltyPolicyLS.setMinRoyalty(ipId2, 100);

        vm.expectRevert(Errors.LicensingModule__DerivativesCannotAddPolicy.selector);
        vm.prank(alice);
        licensingModule.addPolicyToIp(ipId2, _getUmlPolicyId("other_policy"));

        vm.expectRevert(Errors.LicensingModule__DerivativesCannotAddPolicy.selector);
        vm.prank(alice);
        licensingModule.addPolicyToIp(ipId2, _getUmlPolicyId("comm_reciprocal"));
    }
}