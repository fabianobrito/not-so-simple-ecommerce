FROM mcr.microsoft.com/dotnet/sdk:6.0-alpine AS aspnet-building
WORKDIR /nsse-backend-main
COPY . .
RUN dotnet publish /nsse-backend-main/src/services/NotSoSimpleEcommerce.Main/NotSoSimpleEcommerce.Main.csproj \
    -c Release \
    -o publish

FROM mcr.microsoft.com/dotnet/aspnet:6.0-alpine
WORKDIR /nsse-backend-main
COPY --from=aspnet-building /nsse-backend-main/publish /nsse-backend-main/publish
EXPOSE 443

RUN adduser dotnet --disabled-password
RUN apk add curl
USER dotnet
HEALTHCHECK CMD curl -k --fail https://localhost:443/main/health
ENTRYPOINT ["dotnet", "/nsse-backend-main/publish/NotSoSimpleEcommerce.Main.dll"]