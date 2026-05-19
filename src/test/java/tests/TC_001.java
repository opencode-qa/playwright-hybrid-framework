package tests;

import org.testng.Assert;
import org.testng.annotations.AfterTest;
import org.testng.annotations.BeforeTest;
import org.testng.annotations.Test;

import com.microsoft.playwright.Browser;
import com.microsoft.playwright.BrowserContext;
import com.microsoft.playwright.BrowserType;
import com.microsoft.playwright.Page;
import com.microsoft.playwright.Playwright;

public class TC_001 {
    // Playwright objects
    Playwright playwright;
    Browser browser;
    BrowserContext context;
    Page page;

    /**
     * =========================================
     * BEFORE TEST
     * Launch browser and navigate to application
     * =========================================
     */
    @BeforeTest
    public void setup() {

        try {
            System.out.println("========== TEST EXECUTION STARTED ==========");

            // Initialize Playwright
            playwright = Playwright.create();

            // Launch Chrome browser
            browser = playwright.chromium().launch(
                    new BrowserType.LaunchOptions()
                            .setChannel("chrome")
                            .setHeadless(false)
            );

            // Create browser context
            context = browser.newContext();

            // Create new page
            page = context.newPage();

            // Navigate to DemoQA
            page.navigate("https://demoqa.com");

            // Maximize window
            page.setViewportSize(1366, 768);

            System.out.println("Browser launched successfully.");
            System.out.println("Navigated to DemoQA application.");

        } catch (Exception e) {

            System.err.println("Exception occurred during setup.");
            e.printStackTrace();

            Assert.fail("Setup failed: " + e.getMessage());
        }
    }

    /**
     * =========================================
     * TEST METHOD
     * Automate Text Box Form
     * =========================================
     */
    @Test
    public void firstTest() {

        try {

            System.out.println("Text Box Test Started.");

            // Click on Elements card
            page.locator("//h5[text()='Elements']").click();

            // Click on Text Box menu
            page.locator("//span[text()='Text Box']").click();

            // Fill form details
            page.locator("#userName").fill("John Doe");

            page.locator("#userEmail").fill("john.doe@test.com");

            page.locator("#currentAddress")
                    .fill("New Delhi, India");

            page.locator("#permanentAddress")
                    .fill("Bangalore, India");

            // Click Submit button
            page.locator("#submit").click();

            // Validation
            boolean isOutputDisplayed =
                    page.locator("#output").isVisible();

            Assert.assertTrue(
                    isOutputDisplayed,
                    "Text Box form submission failed."
            );

            System.out.println("Text Box Test Passed Successfully.");

        } catch (Exception e) {

            System.err.println("Exception occurred during test execution.");
            e.printStackTrace();

            Assert.fail("Test execution failed: " + e.getMessage());
        }
    }

    /**
     * =========================================
     * AFTER TEST
     * Close browser and cleanup
     * =========================================
     */
    @AfterTest
    public void tearDown() {

        try {

            System.out.println("Closing browser...");

            if (page != null) {
                page.close();
            }

            if (context != null) {
                context.close();
            }

            if (browser != null) {
                browser.close();
            }

            if (playwright != null) {
                playwright.close();
            }

            System.out.println("Browser closed successfully.");
            System.out.println("========== TEST EXECUTION COMPLETED ==========");

        } catch (Exception e) {

            System.err.println("Exception occurred during teardown.");
            e.printStackTrace();
        }
    }
}
