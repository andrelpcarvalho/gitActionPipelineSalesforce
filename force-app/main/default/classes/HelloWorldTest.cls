@isTest
public with sharing class HelloWorldTest {
    isTest static void testHelloWorld() {
        Test.startTest();
        HelloWorld helloWorld = new HelloWorld();
        Test.stopTest();
    }
}